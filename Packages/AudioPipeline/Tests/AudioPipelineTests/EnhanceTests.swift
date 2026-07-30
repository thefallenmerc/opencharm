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
}
