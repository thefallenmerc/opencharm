import AppKit
import SwiftUI

final class CountdownWindow {
    private static var window: NSWindow?

    static func present(seconds: Int = 3, completion: @escaping () -> Void) {
        // A second Start click within the countdown window must not spawn a second timer:
        // that would overwrite `window` and let the first timer's completion close the
        // WRONG window (leaving the real one orphaned) while also double-firing recording.
        guard window == nil else { return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
                           styleMask: .borderless, backing: .buffered, defer: false)
        // This NSWindow is ARC-managed (held only by the `window` static and captured
        // strongly by AppKit machinery); the default `isReleasedWhenClosed = true` would
        // have AppKit also release it on `close()`, over-releasing and risking a
        // use-after-free. ARC alone must own its lifetime.
        win.isReleasedWhenClosed = false
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.ignoresMouseEvents = true
        win.center()
        win.contentView = NSHostingView(rootView: CountdownView(seconds: seconds) { [weak win] in
            // Only clear the static if it still points at the window THIS completion made —
            // a stale completion (if one ever fired late) must never close a newer window.
            if let win, window === win { window = nil }
            win?.close()
            completion()
        })
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

struct CountdownView: View {
    let seconds: Int
    let done: () -> Void
    @State private var remaining: Int = 0

    var body: some View {
        Text(remaining > 0 ? "\(remaining)" : "")
            .font(.system(size: 96, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 180, height: 180)
            .background(.black.opacity(0.6), in: Circle())
            .onAppear {
                remaining = seconds
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                    remaining -= 1
                    if remaining <= 0 { t.invalidate(); done() }
                }
            }
    }
}
