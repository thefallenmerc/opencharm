import CoreGraphics
import XCTest
@testable import Recording
import ProjectStore

final class RecordingEngineTests: XCTestCase {
    @MainActor
    func testFullPipelineScreenOnly() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil)
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording permission")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eng-\(UUID().uuidString).opencharm")
        let engine = RecordingEngine()
        let config = RecordingConfiguration(source: .display(CGMainDisplayID()),
                                            capturesSystemAudio: true, fps: 30)
        try await engine.start(configuration: config, projectURL: url)
        XCTAssertNotEqual(engine.state, .idle)

        // Incremental manifest: offsets must be on disk BEFORE stop (crash recovery),
        // including systemAudio. This pins the fix for a tautology where the engine's
        // completeness guard derived "system audio expected" from the manifest field
        // it was itself about to write, instead of from RecordingConfiguration — which
        // made the guard vacuously true and let the offsets task exit after video alone,
        // silently dropping the system-audio offset from crash recovery. Poll up to the
        // engine's own 5 s offsets-task ceiling (25 * 200 ms) rather than a flat sleep.
        var midRecording = try ProjectPackage.open(at: url)
        let deadline = Date().addingTimeInterval(5)
        while midRecording.manifest.systemAudio == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            midRecording = try ProjectPackage.open(at: url)
        }
        XCTAssertTrue(midRecording.isInterrupted)
        XCTAssertNotNil(midRecording.manifest.systemAudio,
                        "system-audio offset should be persisted incrementally while capturesSystemAudio is true")

        let pkg = try await engine.stop()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertFalse(pkg.isInterrupted)
        XCTAssertEqual(pkg.manifest.screen.startOffset, 0, accuracy: 0.5)
        if let sys = pkg.manifest.systemAudio {
            XCTAssertGreaterThanOrEqual(sys.startOffset, 0)
            XCTAssertLessThan(sys.startOffset, 2.0)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.screenURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.eventsURL.path))
    }
}
