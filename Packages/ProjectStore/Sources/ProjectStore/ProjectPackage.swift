import Foundation

public struct ProjectPackage {
    public let url: URL
    public var manifest: ProjectManifest

    public var screenURL: URL { url.appendingPathComponent("screen.mov") }
    public var webcamURL: URL { url.appendingPathComponent("webcam.mov") }
    public var micURL: URL { url.appendingPathComponent("mic.caf") }
    public var systemAudioURL: URL { url.appendingPathComponent("system.caf") }
    public var eventsURL: URL { url.appendingPathComponent("events.jsonl") }
    public var cacheDir: URL { url.appendingPathComponent("cache") }
    var manifestURL: URL { url.appendingPathComponent("project.json") }
    var lockURL: URL { url.appendingPathComponent("recording.lock") }

    public var isInterrupted: Bool { FileManager.default.fileExists(atPath: lockURL.path) }

    public static func create(at url: URL) throws -> ProjectPackage {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var pkg = ProjectPackage(url: url, manifest: ProjectManifest(
            schemaVersion: ProjectManifest.currentSchemaVersion,
            createdAt: Date(),
            screen: TrackRef(filename: "screen.mov", startOffset: 0),
            renderSettings: .default, audioSettings: .default))
        try pkg.saveManifest()
        return pkg
    }

    public static func open(at url: URL) throws -> ProjectPackage {
        let manifestURL = url.appendingPathComponent("project.json")
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else {
            throw ProjectStoreError.notAPackage(url)
        }
        return ProjectPackage(url: url, manifest: try ManifestMigrator.load(from: data))
    }

    public mutating func saveManifest() throws {
        manifest.schemaVersion = ProjectManifest.currentSchemaVersion
        try ManifestMigrator.save(manifest).write(to: manifestURL, options: .atomic)
    }

    public func markRecordingStarted() throws {
        try Data().write(to: lockURL)
    }
    public func markRecordingFinished() throws {
        try? FileManager.default.removeItem(at: lockURL)
    }
}
