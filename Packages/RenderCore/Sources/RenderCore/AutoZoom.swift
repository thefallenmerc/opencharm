import CoreGraphics
import Foundation

/// User-facing auto-zoom knobs. `level` is the target zoom factor, `speed` (0…1) scales how quickly
/// each zoom eases in/out. Additive-optional on `RenderSettings`; `nil` is treated as `.default`.
public struct AutoZoomSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var level: Double   // target scale, clamped to 1.5…3 when generating
    public var speed: Double   // 0…1, higher = snappier

    public init(enabled: Bool = false, level: Double = 2.0, speed: Double = 0.5) {
        self.enabled = enabled
        self.level = level
        self.speed = speed
    }

    public static let `default` = AutoZoomSettings()
}

/// A single recorded mouse-down, mapped into the screen's normalized space (top-left origin, 0…1),
/// timestamped in composition seconds (same clock as track offsets / `compositionTime`).
public struct ClickEvent: Equatable, Sendable {
    public var time: Double
    public var point: CGPoint
    public init(time: Double, point: CGPoint) {
        (self.time, self.point) = (time, point)
    }
}

/// One computed zoom "hold": between `start` and `end` the screen zooms to `scale` about `focus`
/// (normalized, top-left), easing in over `easeIn` and out over `easeOut` seconds.
public struct ZoomSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var easeIn: Double
    public var easeOut: Double
    public var focus: CGPoint
    public var scale: Double
    public init(start: Double, end: Double, easeIn: Double, easeOut: Double,
                focus: CGPoint, scale: Double) {
        self.start = start; self.end = end
        self.easeIn = easeIn; self.easeOut = easeOut
        self.focus = focus; self.scale = scale
    }
}

/// The evaluated zoom for one instant: `scale` (1 = no zoom) about `focus` (normalized, top-left).
public struct ZoomState: Equatable, Sendable {
    public var scale: Double
    public var focus: CGPoint
    public init(scale: Double, focus: CGPoint) { (self.scale, self.focus) = (scale, focus) }
    public static let identity = ZoomState(scale: 1, focus: CGPoint(x: 0.5, y: 0.5))
}

public enum AutoZoom {
    // Clustering thresholds: clicks within this time gap AND spatial distance fold into one zoom.
    static let timeGap = 1.4          // seconds
    static let spaceGap = 0.22        // normalized distance
    static let tail = 0.7             // linger after the last click in a cluster

    /// Deterministically turns clicks into non-overlapping zoom segments. Empty when disabled or
    /// when there are no clicks.
    public static func segments(clicks: [ClickEvent], settings: AutoZoomSettings) -> [ZoomSegment] {
        guard settings.enabled, !clicks.isEmpty else { return [] }
        let level = min(max(settings.level, 1.5), 3.0)
        let speed = min(max(settings.speed, 0), 1)
        let easeIn = lerp(0.55, 0.22, speed)
        let easeOut = lerp(0.75, 0.32, speed)

        let sorted = clicks.sorted { $0.time < $1.time }
        var clusters: [[ClickEvent]] = []
        for c in sorted {
            if var last = clusters.last, let lastT = last.last?.time,
               c.time - lastT <= timeGap,
               distance(c.point, centroid(last.map(\.point))) <= spaceGap {
                last.append(c)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([c])
            }
        }

        var segments = clusters.map { cluster -> ZoomSegment in
            let focus = centroid(cluster.map(\.point))
            let start = max(0, cluster.first!.time)
            var end = cluster.last!.time + tail
            if end - start < easeIn + easeOut { end = start + easeIn + easeOut }
            return ZoomSegment(start: start, end: end, easeIn: easeIn, easeOut: easeOut,
                               focus: focus, scale: level)
        }

        // Keep segments non-overlapping so the evaluator's "first active" pick is unambiguous.
        for i in 0..<max(0, segments.count - 1) where segments[i].end > segments[i + 1].start {
            segments[i].end = max(segments[i].start, segments[i + 1].start)
        }
        return segments
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n,
                       y: points.map(\.y).reduce(0, +) / n)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

public enum ZoomTimeline {
    /// The zoom to apply at composition time `t`. Segments are non-overlapping and time-ordered.
    public static func state(at t: Double, segments: [ZoomSegment]) -> ZoomState {
        guard let s = segments.first(where: { t >= $0.start && t < $0.end }) else { return .identity }
        let f = envelope(t, s)
        return ZoomState(scale: 1 + (s.scale - 1) * f, focus: s.focus)
    }

    /// 0 at the segment edges, 1 across the hold, smoothstepped through the ease ramps.
    static func envelope(_ t: Double, _ s: ZoomSegment) -> Double {
        if t < s.start + s.easeIn {
            return smoothstep((t - s.start) / max(s.easeIn, 1e-6))
        } else if t > s.end - s.easeOut {
            return smoothstep((s.end - t) / max(s.easeOut, 1e-6))
        }
        return 1
    }

    static func smoothstep(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
