import CoreGraphics
import Foundation

public enum CaptureSpace {
    /// Walks `events` in time order tracking the active capture rect — `initial` until the first
    /// `"rect"` event, then whatever the latest `"rect"` event describes — and returns every
    /// pointer event with its position normalized (0…1, top-left origin) into the rect that was
    /// active at that moment. Pointer events that land outside the active rect, or arrive while
    /// no rect is known, are dropped; `"rect"` events themselves are never emitted.
    public static func normalize(events: [LoggedEvent],
                                 initial: CGRect?) -> [(event: LoggedEvent, point: CGPoint)] {
        var rect = initial
        var out: [(event: LoggedEvent, point: CGPoint)] = []
        for e in events {
            if e.type == "rect" {
                if let w = e.w, let h = e.h, w > 0, h > 0 {
                    rect = CGRect(x: e.x, y: e.y, width: w, height: h)
                }
                continue
            }
            guard let r = rect, r.width > 0, r.height > 0 else { continue }
            let nx = (e.x - r.minX) / r.width
            let ny = (e.y - r.minY) / r.height
            guard (0...1).contains(nx), (0...1).contains(ny) else { continue }
            out.append((event: e, point: CGPoint(x: nx, y: ny)))
        }
        return out
    }
}
