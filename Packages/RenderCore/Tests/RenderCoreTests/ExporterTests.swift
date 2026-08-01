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

    /// Regression test for a discarded `input.append(sb)` Bool result: if the writer
    /// rejects a sample mid-stream, `isReadyForMoreMediaData` goes false permanently and
    /// no further `requestMediaDataWhenReady` callback ever fires, so `pump` must detect
    /// and throw right there instead of leaving its continuation (and therefore `export()`)
    /// hanging forever. Drives `pump` directly against a real reader/writer pair — mirroring
    /// one track of what `export()` wires up.
    ///
    /// The writer is cancelled *synchronously from inside `tick`*, immediately before the
    /// sample that triggered that call would be appended — verified separately to
    /// deterministically make that specific `append()` call return `false` (a
    /// `DispatchQueue.asyncAfter`-timed cancellation was tried first and found racy: it
    /// tends to flip `isReadyForMoreMediaData` false *before* any further append is even
    /// attempted, so the append-failure branch was never actually exercised). Still bounded
    /// by a race against a timeout so a reintroduced hang fails the test instead of hanging
    /// the run.
    func testPumpThrowsInsteadOfHangingWhenWriterFails() async throws {
        let movieURL = try await MovieFixture.make(color: CIColor(red: 1, green: 0, blue: 0), seconds: 2)
        let asset = AVURLAsset(url: movieURL)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(readerOutput)
        XCTAssertTrue(reader.startReading())

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pump-fail-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let tickCount = Locked(0)
        let outcome = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    try await ProjectExporter.pump(input: input, output: readerOutput,
                                                   writer: writer, label: "test") { _ in
                        if tickCount.increment() == 3 { writer.cancelWriting() }
                        return false
                    }
                    return "completed"
                } catch {
                    return "threw"
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return "timed out"
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertEqual(outcome, "threw",
                       "pump must throw once append fails, not hang or silently complete")

        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: movieURL)
    }

    /// Minimal `NSLock`-guarded counter so the `tick` closure above (`@Sendable`, called
    /// from `pump`'s dedicated serial queue) can count invocations without a data race.
    private final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ value: Int) { self.value = value }
        @discardableResult
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// A pre-cancelled exporter must short-circuit before paying for the composition build.
    func testCancelBeforeExportThrowsWithoutBuilding() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1))
        var settings = RenderSettings.default
        settings.webcam.visible = false
        let exporter = ProjectExporter(
            timeline: MediaTimeline(screen: .init(url: screenURL, startOffset: 0), webcam: nil, audio: []),
            settings: settings, sourceCanvasSize: CGSize(width: 320, height: 240),
            backgroundImage: nil)
        exporter.cancel()

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).mp4")
        let start = Date()
        do {
            try await exporter.export(
                ExportRequest(outputURL: out, codec: .h264, resolution: .source)) { _ in }
            XCTFail("expected a pre-flight cancellation error")
        } catch let error as ExportError {
            guard case .cancelled = error else { XCTFail("expected .cancelled, got \(error)"); return }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0,
                          "an already-cancelled export should short-circuit before the composition build")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    /// A writer that can't start (bad output location) must throw `.failed` and leave no
    /// partial file, exercising the pre-flight `startReading()/startWriting()` guard branch.
    func testStartWritingFailureThrowsAndLeavesNoPartialFile() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1))
        var settings = RenderSettings.default
        settings.webcam.visible = false
        let exporter = ProjectExporter(
            timeline: MediaTimeline(screen: .init(url: screenURL, startOffset: 0), webcam: nil, audio: []),
            settings: settings, sourceCanvasSize: CGSize(width: 320, height: 240),
            backgroundImage: nil)

        // A nonexistent parent directory makes `AVAssetWriter.init` succeed but
        // `startWriting()` return false.
        let badDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        let out = badDir.appendingPathComponent("out.mp4")

        do {
            try await exporter.export(
                ExportRequest(outputURL: out, codec: .h264, resolution: .source)) { _ in }
            XCTFail("expected export to throw when the writer can't start")
        } catch let error as ExportError {
            guard case .failed = error else { XCTFail("expected .failed, got \(error)"); return }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "no partial output file should be left behind")
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
