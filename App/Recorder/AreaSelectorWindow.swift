import AppKit
import SwiftUI

/// Full-screen transparent overlay; drag to select a rect. Esc cancels, releasing confirms.
final class AreaSelectorWindow: NSWindow {
    static func present(onSelect: @escaping (CGDirectDisplayID, CGRect) -> Void) {
        guard let screen = NSScreen.main else { return }
        let win = AreaSelectorWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // ARC (not AppKit) owns this window's lifetime — see CountdownWindow.swift for the
        // same reasoning. Without this, `close()` below over-releases it.
        win.isReleasedWhenClosed = false
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.ignoresMouseEvents = false
        win.contentView = NSHostingView(rootView: AreaSelectionView { [weak win] rect in
            let displayID = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID(truncating: $0) } ?? CGMainDisplayID()
            // Convert AppKit (bottom-left origin) view coords → display points, top-left origin.
            let flipped = CGRect(x: rect.minX,
                                 y: screen.frame.height - rect.maxY,
                                 width: rect.width, height: rect.height)
            win?.close()
            onSelect(displayID, flipped)
        } onCancel: { [weak win] in win?.close() })
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

struct AreaSelectionView: View {
    let onDone: (CGRect) -> Void
    let onCancel: () -> Void
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var rect: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.25)
                if let r = rect {
                    Path { $0.addRect(r) }
                        .stroke(Color.accentColor, lineWidth: 2)
                    Text("\(Int(r.width))×\(Int(r.height)) — release to confirm")
                        .font(.caption).padding(6)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                        .position(x: r.midX, y: max(r.minY - 18, 12))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if start == nil { start = v.startLocation }
                    current = v.location
                }
                .onEnded { _ in
                    // SwiftUI coords here are top-left origin; convert to AppKit bottom-left.
                    if let r = rect, r.width > 24, r.height > 24 {
                        let appkitRect = CGRect(x: r.minX, y: geo.size.height - r.maxY,
                                                width: r.width, height: r.height)
                        onDone(appkitRect)
                    } else { onCancel() }
                })
        }
        .ignoresSafeArea()
    }
}
