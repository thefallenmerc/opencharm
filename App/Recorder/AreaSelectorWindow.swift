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
            let full = CGRect(origin: .zero, size: geo.size)
            ZStack {
                // Bluish dim over everything except the selection — the even-odd rule cuts a
                // clear hole where the chosen area is, so it reads brighter than the surround.
                Path { p in
                    p.addRect(full)
                    if let r = rect { p.addRect(r) }
                }
                .fill(Color(.sRGB, red: 0.10, green: 0.14, blue: 0.30, opacity: 0.32),
                      style: FillStyle(eoFill: true))
                if let r = rect {
                    Path { $0.addRect(r) }
                        .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    cornerBrackets(for: r)
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

    /// Decorative inward L-brackets at each selection corner (Screen Charm-style resize markers).
    /// Purely visual — the selection still confirms on release, with no resize/edit phase.
    private func cornerBrackets(for r: CGRect) -> some View {
        let leg: CGFloat = 18
        return Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY + leg))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + leg, y: r.minY))

            p.move(to: CGPoint(x: r.maxX - leg, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + leg))

            p.move(to: CGPoint(x: r.minX, y: r.maxY - leg))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + leg, y: r.maxY))

            p.move(to: CGPoint(x: r.maxX - leg, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - leg))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}
