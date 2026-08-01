import AVFoundation
import CoreImage
import XCTest
@testable import RenderCore

final class ExporterTests: XCTestCase {
    func testPixelSizeMath() {
        let src = CGSize(width: 1437, height: 899)
        XCTAssertEqual(ProjectExporter.pixelSize(for: .source, sourceCanvas: src),
                       CGSize(width: 1436, height: 898))
        let hd = ProjectExporter.pixelSize(for: .fullHD1080, sourceCanvas: CGSize(width: 3456, height: 2160))
        XCTAssertEqual(hd, CGSize(width: 1728, height: 1080))
        let uhd = ProjectExporter.pixelSize(for: .uhd4K, sourceCanvas: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(uhd, CGSize(width: 3840, height: 2160))
    }

    func testExportsPlayableMP4WithAudio() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1))
        // 2 s of quiet noise as mic audio.
        var samples = [Float](repeating: 0, count: 96_000)
        for i in samples.indices { samples[i] = Float.random(in: -0.1...0.1) }
        let micURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-\(UUID().uuidString).caf")
        try writeCAF(samples, to: micURL)

        var settings = RenderSettings.default
        settings.webcam.visible = false
        let exporter = ProjectExporter(
            timeline: MediaTimeline(screen: .init(url: screenURL, startOffset: 0),
                                    webcam: nil,
                                    audio: [.init(url: micURL, startOffset: 0, volume: 1)]),
            settings: settings, sourceCanvasSize: CGSize(width: 320, height: 240),
            backgroundImage: nil)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).mp4")
        var lastProgress = 0.0
        try await exporter.export(
            ExportRequest(outputURL: out, codec: .h264, resolution: .source)) { p in
            lastProgress = max(lastProgress, p)
        }
        XCTAssertGreaterThan(lastProgress, 0.5)

        let asset = AVURLAsset(url: out)
        // Swift disallows an `await` call directly inside XCTAssertEqual's (non-async)
        // autoclosure arguments, so the loaded values are bound to locals first.
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.3)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let size = try await videoTracks[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 240))
    }

    private func writeCAF(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format,
                                   frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
    }
}
