import AppKit
import ProjectStore
import SwiftUI

/// AppKit-owned Studio window. Replaces the SwiftUI `Window` scene so any code path
/// (stop-flow, launch recovery, Open Project) can open it directly, without the
/// lazy-scene `openWindow` environment plumbing. Also prompts to save the project to a
/// portable `.charmproj` when the window is closed (or the app quit) with unsaved work.
@MainActor
final class StudioWindowController: NSWindowController, NSWindowDelegate {
    /// Same-instance reuse per project URL — prevents rebuilding a StylingModel
    /// (AVPlayer + initialLoad task) every time the same project is shown.
    private var models: [URL: StylingModel] = [:]
    private var current: StylingModel?
    private var forceClose = false // set once a save/discard decision has been made

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OpenCharm Studio"
        // Fixed 300pt inspector sidebar + a 1pt divider + the 480pt preview minimum.
        window.minSize = NSSize(width: 820, height: 420)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(package: ProjectPackage, savedArchive: URL? = nil) {
        let model: StylingModel
        if let existing = models[package.url] {
            model = existing
        } else {
            model = StylingModel(package: package, savedArchiveURL: savedArchive)
            models[package.url] = model
        }
        current = model
        window?.contentView = NSHostingView(rootView: StylingView(model: model))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: save-on-close

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forceClose || current?.needsSavePrompt != true { return true }
        guard let window, let model = current else { return true }
        let alert = makeSaveAlert(model)
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            switch resp {
            case .alertFirstButtonReturn: // Save…
                Task { @MainActor in
                    if await model.saveProject() { self.forceClose = true; window.close() }
                }
            case .alertSecondButtonReturn: // Don't Save
                self.forceClose = true
                window.close()
            default: break // Cancel — keep the window open
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        forceClose = false // reset for the next open/close cycle
    }

    /// Called from `applicationShouldTerminate` — app-modal prompt (no sheet host during quit).
    func promptSaveForTermination() -> NSApplication.TerminateReply {
        guard window?.isVisible == true, let model = current, model.needsSavePrompt else {
            return .terminateNow
        }
        switch makeSaveAlert(model).runModal() {
        case .alertFirstButtonReturn: // Save…
            Task { @MainActor in
                let ok = await model.saveProject()
                NSApp.reply(toApplicationShouldTerminate: ok) // proceed only if it actually saved
            }
            return .terminateLater
        case .alertSecondButtonReturn: // Don't Save
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func makeSaveAlert(_ model: StylingModel) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Save this project?"
        alert.informativeText =
            "Save “\(model.projectName)” as a .charmproj so you can reopen or share it. "
            + "The recording stays in OpenCharm’s library either way."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
