import AppKit
import ProjectStore
import SwiftUI

/// AppKit-owned Studio window. Replaces the SwiftUI `Window` scene so any code path
/// (stop-flow, launch recovery, Open Project) can open it directly, without the
/// lazy-scene `openWindow` environment plumbing.
@MainActor
final class StudioWindowController: NSWindowController {
    /// Same-instance reuse per project URL — prevents rebuilding a StylingModel
    /// (AVPlayer + initialLoad task) every time the same project is shown.
    private var models: [URL: StylingModel] = [:]

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(package: ProjectPackage) {
        let model: StylingModel
        if let existing = models[package.url] {
            model = existing
        } else {
            model = StylingModel(package: package)
            models[package.url] = model
        }
        window?.contentView = NSHostingView(rootView: StylingView(model: model))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
