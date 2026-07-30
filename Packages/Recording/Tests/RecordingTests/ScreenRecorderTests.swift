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
}
