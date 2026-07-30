import AVFoundation
import XCTest
@testable import AudioPipeline

final class EnhanceTests: XCTestCase {
    /// 50 Hz rumble + 1 kHz tone. Enhance must gut the rumble and keep the tone.
    func makeRumbleFixture() throws -> URL {
        let sr = 48_000.0
        let frames = Int(sr * 2)
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sr
            samples[i] = Float(sin(2 * .pi * 50 * t)) * 0.5
                       + Float(sin(2 * .pi * 1000 * t)) * 0.2
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rumble-\(UUID().uuidString).caf")
        try AudioProcessor.writeMono48k(samples, to: url)
        return url
    }

    /// Goertzel power of one frequency over the whole file.
    func power(at hz: Double, in url: URL) throws -> Double {
        let samples = try AudioProcessor.readMono48k(url)
        let w = 2 * .pi * hz / 48_000
        var (s0, s1, s2) = (0.0, 0.0, 0.0)
        for x in samples {
            s0 = Double(x) + 2 * cos(w) * s1 - s2
            s2 = s1; s1 = s0
        }
        return s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
    }

    func testEnhanceRemovesRumbleKeepsVoiceBand() throws {
        let input = try makeRumbleFixture()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("enh-\(UUID().uuidString).caf")
        try AudioProcessor.enhance(input: input, output: output)

        let rumbleDrop = 10 * log10(try power(at: 50, in: input) / max(try power(at: 50, in: output), 1e-12))
        XCTAssertGreaterThanOrEqual(rumbleDrop, 12, "50 Hz only dropped \(rumbleDrop) dB")
        let toneDrop = 10 * log10(try power(at: 1000, in: input) / max(try power(at: 1000, in: output), 1e-12))
        XCTAssertLessThanOrEqual(abs(toneDrop), 6, "1 kHz changed by \(toneDrop) dB")

        // No clipping.
        let out = try AudioProcessor.readMono48k(output)
        XCTAssertLessThanOrEqual(out.map(abs).max() ?? 0, 1.0)
    }

    func testProcessChainAndPassthrough() throws {
        let input = try makeRumbleFixture()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("chain-\(UUID().uuidString).caf")
        try AudioProcessor.process(input: input, output: out, denoise: true, enhance: true)
        XCTAssertEqual(try AVAudioFile(forReading: out).processingFormat.sampleRate, 48_000)
    }

    /// `enhance` computes its total render-frame count from a sample-rate ratio
    /// (`file.length * 48_000 / file.processingFormat.sampleRate`); every other
    /// fixture in this file is already 48 kHz, so that ratio is always 1.0 and
    /// this arithmetic has never actually been exercised at ratio != 1.0. Drives
    /// a 44.1 kHz mono fixture through the real AVAudioEngine offline-render
    /// chain (not `readMono48k`'s AVAudioConverter path, which is separately
    /// covered by DenoiseTests) to confirm it still resamples to 48 kHz mono
    /// without truncating or corrupting the duration.
    func testEnhanceHandlesNonNativeSampleRateInput() throws {
        let sr = 44_100.0
        let seconds = 1.5
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            p[i] = Float(sin(2 * .pi * 300 * t)) * 0.3
        }
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("in44k-\(UUID().uuidString).caf")
        let inFile = try AVAudioFile(forWriting: input, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try inFile.write(from: buf)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("enh44k-\(UUID().uuidString).caf")
        try AudioProcessor.enhance(input: input, output: output)

        let outFile = try AVAudioFile(forReading: output)
        XCTAssertEqual(outFile.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(outFile.processingFormat.channelCount, 1)
        let outSeconds = Double(outFile.length) / 48_000
        XCTAssertEqual(outSeconds, seconds, accuracy: 0.1,
                       "output duration \(outSeconds)s should be ~\(seconds)s")
    }

    /// `process`'s (true,true) branch is covered by testProcessChainAndPassthrough
    /// above; this covers the other three dispatch branches so all four are
    /// exercised — each must produce a readable 48 kHz mono CAF of the input's
    /// duration.
    func testProcessDispatchBranches() throws {
        let sr = 48_000.0
        let seconds = 0.5
        var samples = [Float](repeating: 0, count: Int(sr * seconds))
        for i in samples.indices {
            samples[i] = Float(sin(Double(i) * 0.1)) * 0.3
        }
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("proc-in-\(UUID().uuidString).caf")
        try AudioProcessor.writeMono48k(samples, to: input)

        let cases: [(denoise: Bool, enhance: Bool)] = [
            (false, false), (true, false), (false, true),
        ]
        for c in cases {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("proc-out-\(UUID().uuidString).caf")
            try AudioProcessor.process(input: input, output: output,
                                       denoise: c.denoise, enhance: c.enhance)
            let outFile = try AVAudioFile(forReading: output)
            XCTAssertEqual(outFile.processingFormat.sampleRate, 48_000,
                           "denoise=\(c.denoise) enhance=\(c.enhance)")
            XCTAssertEqual(outFile.processingFormat.channelCount, 1,
                           "denoise=\(c.denoise) enhance=\(c.enhance)")
            let outSeconds = Double(outFile.length) / 48_000
            XCTAssertEqual(outSeconds, seconds, accuracy: 0.05,
                           "denoise=\(c.denoise) enhance=\(c.enhance): duration \(outSeconds)s")
        }
    }

    /// A mid-generation failure must never leave a partial/corrupt file at
    /// `output`: `enhance` renders to a temp file and only moves it into place
    /// on full success. Verifies both halves — the pre-existing destination is
    /// untouched, and no `.tmp-*` file is left behind — using an input that
    /// makes `AVAudioFile(forReading:)` throw before any rendering happens.
    func testEnhanceFailureLeavesExistingOutputUntouchedAndNoTempLitter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let output = dir.appendingPathComponent("out.caf")
        let sentinel = Data("not a real caf".utf8)
        try sentinel.write(to: output)

        let badInput = dir.appendingPathComponent("bad-input.caf")
        try Data("garbage".utf8).write(to: badInput)

        XCTAssertThrowsError(try AudioProcessor.enhance(input: badInput, output: output))

        // Output must be exactly what it was before the failed call — never
        // partially overwritten.
        XCTAssertEqual(try Data(contentsOf: output), sentinel)

        // No `.tmp-*` leftovers in the destination directory.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "temp files left behind: \(leftovers)")
    }
}
