import XCTest
@testable import ProjectStore

final class PackageTests: XCTestCase {
    func tempPackageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("t-\(UUID().uuidString).opencharm")
    }

    func testCreateOpenLifecycle() throws {
        let url = tempPackageURL()
        var pkg = try ProjectPackage.create(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(pkg.screenURL.lastPathComponent, "screen.mov")
        XCTAssertEqual(pkg.cacheDir.lastPathComponent, "cache")

        try pkg.markRecordingStarted()
        XCTAssertTrue(pkg.isInterrupted)
        pkg.manifest.screen.startOffset = 0.5
        try pkg.saveManifest()
        try pkg.markRecordingFinished()
        XCTAssertFalse(pkg.isInterrupted)

        let reopened = try ProjectPackage.open(at: url)
        XCTAssertEqual(reopened.manifest.screen.startOffset, 0.5, accuracy: 0.0001)
    }

    func testOpenRejectsNonPackage() {
        XCTAssertThrowsError(try ProjectPackage.open(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("nope.opencharm")))
    }
}
