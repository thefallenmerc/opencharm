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
        try await Task.sleep(for: .seconds(3))

        // Incremental manifest: offsets must be on disk BEFORE stop (crash recovery).
        let midRecording = try ProjectPackage.open(at: url)
        XCTAssertTrue(midRecording.isInterrupted)

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
