import XCTest
@testable import ProjectStore

final class LibraryTests: XCTestCase {
    func testNewProjectURLNaming() {
        let dir = FileManager.default.temporaryDirectory
        let url = ProjectLibrary.newProjectURL(in: dir)
        XCTAssertEqual(url.pathExtension, "opencharm")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Recording "))
    }

    func testInterruptedScan() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = try ProjectPackage.create(at: dir.appendingPathComponent("a.opencharm"))
        _ = try ProjectPackage.create(at: dir.appendingPathComponent("b.opencharm"))
        try a.markRecordingStarted()
        XCTAssertEqual(ProjectLibrary.projects(in: dir).count, 2)
        XCTAssertEqual(ProjectLibrary.interruptedProjects(in: dir),
                       [dir.appendingPathComponent("a.opencharm")])
    }
}
