import AppKit
import SwiftUI

/// Floating, nonactivating, draggable dock chrome. Content is SwiftUI (DockView).
/// Position persists across launches via UserDefaults.
final class DockPanel: NSPanel, NSWindowDelegate {
    private static let originKey = "DockPanelOrigin"

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        delegate = self

        let host = NSHostingView(rootView: content)
        // Resize the panel whenever the SwiftUI content's ideal size changes —
        // this is what shrinks the dock into the stop bar and back.
        host.sizingOptions = [.preferredContentSize]
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 120)
        contentView = host
        setContentSize(host.fittingSize)

        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2,
                                   y: f.minY + f.height * 0.18))
        }
    }

    // Popovers and buttons inside need key status; nonactivating panels may refuse it
    // by default for borderless masks.
    override var canBecomeKey: Bool { true }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }
}
