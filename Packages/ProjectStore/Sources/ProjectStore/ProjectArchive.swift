import Foundation

public enum ProjectArchiveError: Error, Equatable {
    case dittoFailed(Int32)
    case noPackageInArchive
}

/// Reads/writes a portable `.charmproj` archive — a PKZip of a project's `.opencharm` package — using
/// `/usr/bin/ditto`. (The app is not sandboxed, so spawning `ditto` is permitted, and `ditto` handles
/// both zipping and unzipping without a third-party dependency.)
public enum ProjectArchive {
    /// Zips the package directory at `packageURL` into a single `.charmproj` file at `dest`
    /// (overwriting any existing file). `--keepParent` embeds the `.opencharm` folder as the archive
    /// root so `unpack` can find it.
    public static func write(packageURL: URL, to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        try runDitto(["-c", "-k", "--keepParent", packageURL.path, dest.path])
    }

    /// Unpacks `archiveURL` into `dir`, returning the extracted `.opencharm` package URL (given a
    /// unique name under `dir`). A stray `recording.lock` is removed so the unpacked copy is never
    /// mistaken for an interrupted recording by crash recovery.
    @discardableResult
    public static func unpack(archiveURL: URL, into dir: URL) throws -> URL {
        let fm = FileManager.default
        let tmp = dir.appendingPathComponent(".unpack-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try runDitto(["-x", "-k", archiveURL.path, tmp.path])

        let entries = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        guard let src = entries.first(where: { $0.pathExtension == "opencharm" }) else {
            throw ProjectArchiveError.noPackageInArchive
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = src.deletingPathExtension().lastPathComponent
        var dest = dir.appendingPathComponent("\(base).opencharm")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(n).opencharm"); n += 1
        }
        try fm.moveItem(at: src, to: dest)
        try? fm.removeItem(at: dest.appendingPathComponent("recording.lock"))
        return dest
    }

    private static func runDitto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw ProjectArchiveError.dittoFailed(p.terminationStatus) }
    }
}
