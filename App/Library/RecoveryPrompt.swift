import AppKit
import ProjectStore

enum RecoveryPrompt {
    /// Returns the package if the user chose to recover an interrupted recording.
    @MainActor
    static func checkOnLaunch() -> ProjectPackage? {
        guard let url = ProjectLibrary.interruptedProjects().first else { return nil }
        let alert = NSAlert()
        alert.messageText = "Recover interrupted recording?"
        alert.informativeText =
            "\(url.deletingPathExtension().lastPathComponent) was interrupted (app quit while recording). The captured video up to the last moment can be recovered. The recovered project will open in the Studio window — click the OpenCharm menu bar icon if it doesn't appear."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Delete It")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard var pkg = try? ProjectPackage.open(at: url) else { return nil }
            try? pkg.markRecordingFinished()
            try? pkg.saveManifest()
            return pkg
        default:
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}
