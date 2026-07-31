import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import Recording

final class ScreenRecorderTests: XCTestCase {
    func testRecordsTwoSecondsOfMainDisplay() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "no screen on CI")
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording permission")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let videoURL = dir.appendingPathComponent("screen.mov")
        let audioURL = dir.appendingPathComponent("system.caf")

        let config = RecordingConfiguration(
            source: .display(CGMainDisplayID()), capturesSystemAudio: true, fps: 30)
        let recorder = ScreenRecorder(configuration: config, videoURL: videoURL,
                                      systemAudioURL: audioURL)
        try await recorder.start()
        try await Task.sleep(for: .seconds(2))
        try await recorder.stop()

        XCTAssertNotNil(recorder.videoFirstPTS)
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 1.0)
        let size = try await asset.loadTracks(withMediaType: .video)[0].load(.naturalSize)
        XCTAssertEqual(size, recorder.capturePixelSize)
        // System audio file exists (SCK emits audio even for silence).
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    /// `interleaved(_:)` reinterprets planar channel memory as `Float32` — it must only do that
    /// for buffers actually confirmed to be 32-bit float PCM. A non-interleaved 16-bit integer
    /// buffer (a shape ScreenCaptureKit never sends today, but the guard must reject regardless
    /// of source) must fall through to the pass-through branch untouched, not get misread.
    func testInterleavedPassesThroughNonFloatPCM() {
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        let source = SampleBufferFactory.nonInterleavedInt16Buffer(pts: start)

        let result = ScreenRecorder.interleaved(source)

        XCTAssertTrue(result === source, "non-Float32 PCM must pass through as the same buffer, not a rebuilt one")
        guard let result else { return }
        guard let format = CMSampleBufferGetFormatDescription(result),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            XCTFail("expected a valid audio format description")
            return
        }
        XCTAssertEqual(asbd.mBitsPerChannel, 16)
        XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, kAudioFormatFlagIsFloat)
        XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
    }
}
