import AppKit
import CoreMedia
import Foundation

public struct LoggedEvent: Codable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double
    public var type: String
    public init(t: Double, x: Double, y: Double, type: String) {
        (self.t, self.x, self.y, self.type) = (t, x, y, type)
    }
}

public final class EventLogger {
    private let fileURL: URL
    private var events: [LoggedEvent] = []
    private var monitors: [Any] = []
    private var lastMoveT: Double = -1
    private let queue = DispatchQueue(label: "eventlogger")

    /// Set by RecordingEngine once all first-sample timestamps are known.
    public var epoch: Double?

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp,
                                           .leftMouseDragged, .rightMouseDown, .rightMouseUp]
        func handle(_ event: NSEvent) {
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            let loc = NSEvent.mouseLocation // bottom-left → top-left: Quartz global space (primary-anchored)
            let type: String
            switch event.type {
            case .leftMouseDown, .rightMouseDown: type = "down"
            case .leftMouseUp, .rightMouseUp: type = "up"
            default: type = "move"
            }
            self.log(LoggedEvent(t: now, x: loc.x, y: screenH - loc.y, type: type))
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    public func log(_ event: LoggedEvent) {
        queue.sync {
            if event.type == "move" {
                guard event.t - lastMoveT >= 1.0 / 120.0 else { return }
                lastMoveT = event.t
            }
            events.append(event)
        }
    }

    public func finalize(epoch: Double) throws {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        let encoder = JSONEncoder()
        var out = ""
        try queue.sync {
            for var e in events {
                e.t -= epoch
                out += String(data: try encoder.encode(e), encoding: .utf8)! + "\n"
            }
        }
        try out.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
