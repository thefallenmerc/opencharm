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
        clampToScreen()
    }

    // Popovers and buttons inside need key status; nonactivating panels may refuse it
    // by default for borderless masks.
    override var canBecomeKey: Bool { true }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }

    // The content resizes after SwiftUI lays out its fitting size, and when the dock morphs into
    // the compact stop bar and back. Re-clamp so a grow near an edge can't push it off-screen.
    func windowDidResize(_ notification: Notification) {
        clampToScreen()
    }

    /// Keeps the whole panel inside the active screen's `visibleFrame` — which already excludes the
    /// menu bar and the macOS Dock — so it never launches off-screen or hidden behind the Dock.
    /// Also self-heals a stale saved origin (moved window, a display that's since been disconnected).
    private func clampToScreen() {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main else { return }
        let v = screen.visibleFrame.insetBy(dx: 8, dy: 8) // small margin off the edges/Dock
        var o = frame.origin
        o.x = min(max(o.x, v.minX), v.maxX - frame.width)
        o.y = min(max(o.y, v.minY), v.maxY - frame.height)
        if frame.width > v.width { o.x = v.minX }   // panel wider than the usable area
        if frame.height > v.height { o.y = v.minY }
        if o != frame.origin { setFrameOrigin(o) }
    }
}
