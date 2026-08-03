import XCTest
@testable import ProjectStore

final class ProjectArchiveTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWriteThenUnpackRoundTrips() throws {
        let fm = FileManager.default
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }

        let pkg = root.appendingPathComponent("Demo.opencharm")
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("screen".utf8).write(to: pkg.appendingPathComponent("screen.mov"))
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: pkg.appendingPathComponent("project.json"))
        try Data(repeating: 7, count: 2048).write(to: pkg.appendingPathComponent("webcam.mov"))
        try Data().write(to: pkg.appendingPathComponent("recording.lock")) // must be stripped on unpack

        let archive = root.appendingPathComponent("Demo.charmproj")
        try ProjectArchive.write(packageURL: pkg, to: archive)
        XCTAssertTrue(fm.fileExists(atPath: archive.path))
        XCTAssertGreaterThan((try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 0)

        let restored = try ProjectArchive.unpack(archiveURL: archive, into: root.appendingPathComponent("out"))
        XCTAssertEqual(restored.pathExtension, "opencharm")
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("screen.mov")), Data("screen".utf8))
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("webcam.mov")).count, 2048)
        XCTAssertFalse(fm.fileExists(atPath: restored.appendingPathComponent("recording.lock").path))
    }

    func testUnpackAssignsUniqueNameOnCollision() throws {
        let fm = FileManager.default
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let pkg = root.appendingPathComponent("Demo.opencharm")
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("s".utf8).write(to: pkg.appendingPathComponent("screen.mov"))
        let archive = root.appendingPathComponent("Demo.charmproj")
        try ProjectArchive.write(packageURL: pkg, to: archive)

        let out = root.appendingPathComponent("lib")
        let first = try ProjectArchive.unpack(archiveURL: archive, into: out)
        let second = try ProjectArchive.unpack(archiveURL: archive, into: out)
        XCTAssertNotEqual(first, second)          // didn't clobber the first copy
        XCTAssertTrue(fm.fileExists(atPath: first.path))
    }

    func testUnpackRejectsArchiveWithoutPackage() throws {
        let fm = FileManager.default
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: plain.appendingPathComponent("a.txt"))
        let archive = root.appendingPathComponent("bad.charmproj")
        try ProjectArchive.write(packageURL: plain, to: archive) // no *.opencharm inside
        XCTAssertThrowsError(try ProjectArchive.unpack(archiveURL: archive,
                                                       into: root.appendingPathComponent("o")))
    }
}
