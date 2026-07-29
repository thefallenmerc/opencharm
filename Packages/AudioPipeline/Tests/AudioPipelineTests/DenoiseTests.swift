import AVFoundation
import XCTest
@testable import AudioPipeline

final class DenoiseTests: XCTestCase {
    func makeNoisyFixture() throws -> URL {
        let sr = 48_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                   channels: 1, interleaved: false)!
        let seconds = 4.0
        let frames = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        var seed: UInt64 = 42
        func noise() -> Float { // deterministic xorshift white noise
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Float(Int64(bitPattern: seed % 20000) - 10000) / 10000.0
        }
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let hiss = noise() * 0.05                      // ~ -26 dBFS floor everywhere
            let voiceish = (1.0...3.0).contains(t)
                ? Float(sin(2 * .pi * 210 * t)) * 0.4 * Float(abs(sin(2 * .pi * 3 * t)))
                : 0
            p[i] = hiss + voiceish
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noisy-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buf)
        return url
    }

    func rms(_ url: URL, from: Double, to: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(from * sr)
        let count = AVAudioFrameCount((to - from) * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: buf, frameCount: count)
        let p = buf.floatChannelData![0]
        var sum = 0.0
        for i in 0..<Int(buf.frameLength) { sum += Double(p[i] * p[i]) }
        return sqrt(sum / Double(buf.frameLength))
    }

    func testDenoiseReducesNoiseFloor() throws {
        let input = try makeNoisyFixture()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("clean-\(UUID().uuidString).caf")
        try AudioProcessor.denoise(input: input, output: output)

        let before = try rms(input, from: 3.3, to: 3.9)   // hiss-only tail
        let after = try rms(output, from: 3.3, to: 3.9)
        let dropDB = 20 * log10(before / max(after, 1e-9))
        XCTAssertGreaterThanOrEqual(dropDB, 10, "noise floor only dropped \(dropDB) dB")

        let outFile = try AVAudioFile(forReading: output)
        XCTAssertEqual(outFile.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(outFile.processingFormat.channelCount, 1)
        let inLen = Double(try AVAudioFile(forReading: input).length) / 48_000
        let outLen = Double(outFile.length) / 48_000
        XCTAssertEqual(inLen, outLen, accuracy: 0.1)
    }

    /// `readMono48k`'s AVAudioConverter resample+downmix path (any-input-format
    /// contract) had zero coverage: the only fixture above is already 48 kHz
    /// mono, so it never exercises `AVAudioConverter`. This drives a stereo
    /// 44.1 kHz fixture through it.
    func makeStereo44_1kFixture(seconds: Double = 2.0) throws -> URL {
        let sr = 44_100.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                   channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let left = buf.floatChannelData![0]
        let right = buf.floatChannelData![1]
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            // Voice-like: carrier amplitude-modulated by a slow envelope for the
            // full duration (not just a mid-section), so the converter's tail —
            // where a partial-drain bug would truncate or zero out — has real
            // signal to check for. Channels differ slightly to exercise an
            // actual downmix rather than a trivial duplicate.
            let carrier = Float(sin(2 * .pi * 220 * t))
            let envelope = Float(abs(sin(2 * .pi * 2.5 * t)))
            left[i] = carrier * 0.5 * envelope
            right[i] = carrier * 0.4 * envelope
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stereo-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buf)
        return url
    }

    func testDenoiseConvertsStereo44_1kInput() throws {
        let input = try makeStereo44_1kFixture()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("stereo-clean-\(UUID().uuidString).caf")
        try AudioProcessor.denoise(input: input, output: output)

        let outFile = try AVAudioFile(forReading: output)
        XCTAssertEqual(outFile.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(outFile.processingFormat.channelCount, 1)

        let inLen = Double(try AVAudioFile(forReading: input).length) / 44_100
        let outLen = Double(outFile.length) / 48_000
        XCTAssertEqual(inLen, outLen, accuracy: 0.1)

        // Non-silence right at the tail proves the converter fully drained
        // instead of truncating: a partial-drain bug tends to leave the frame
        // count looking plausible while zeroing or dropping exactly this
        // region.
        let tailRMS = try rms(output, from: outLen - 0.3, to: outLen - 0.05)
        XCTAssertGreaterThan(tailRMS, 0.01,
            "output is unexpectedly silent near the tail (RMS \(tailRMS)) — conversion may have truncated")
    }
}
