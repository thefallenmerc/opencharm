import Foundation

public enum ProjectLibrary {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCharm")
    }

    public static func newProjectURL(in dir: URL = defaultDirectory) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("Recording \(fmt.string(from: Date())).opencharm")
    }

    public static func projects(in dir: URL = defaultDirectory) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            // Standardize: contentsOfDirectory resolves the real path (e.g. under
            // /private/var on macOS), while callers typically build URLs from the
            // unresolved form (e.g. FileManager.temporaryDirectory, /var). Without
            // this, otherwise-identical URLs compare unequal.
            .map { $0.standardizedFileURL }
            .filter { $0.pathExtension == "opencharm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func interruptedProjects(in dir: URL = defaultDirectory) -> [URL] {
        projects(in: dir).filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("recording.lock").path)
        }
    }
}
