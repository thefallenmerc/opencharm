import CoreGraphics
import Foundation

/// User-facing auto-zoom knobs. `level` is the target zoom factor, `speed` (0…1) scales how quickly
/// each zoom eases in/out. Additive-optional on `RenderSettings`; `nil` is treated as `.default`.
public struct AutoZoomSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var level: Double   // target scale, clamped to 1.5…3 when generating
    public var speed: Double   // 0…1, higher = snappier

    public init(enabled: Bool = true, level: Double = 2.0, speed: Double = 0.5) {
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

/// A focus target at a point in time. A held zoom carries a list of these and *pans* between them,
/// so the view stays magnified and glides to a new region instead of zooming out and back in.
public struct FocusKey: Codable, Equatable, Sendable {
    public var time: Double
    public var point: CGPoint // normalized, top-left
    public init(time: Double, point: CGPoint) { (self.time, self.point) = (time, point) }
}

/// One computed zoom "hold": between `start` and `end` the screen zooms to `scale`, easing in over
/// `easeIn` and out over `easeOut`. The focus follows `focusKeys` (a single key = a static focus;
/// multiple keys = a pan that arrives at each key's time).
public struct ZoomSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var easeIn: Double
    public var easeOut: Double
    public var scale: Double
    public var focusKeys: [FocusKey]

    public init(start: Double, end: Double, easeIn: Double, easeOut: Double,
                scale: Double, focusKeys: [FocusKey]) {
        self.start = start; self.end = end
        self.easeIn = easeIn; self.easeOut = easeOut
        self.scale = scale; self.focusKeys = focusKeys
    }

    /// Convenience for a static (single-focus) zoom.
    public init(start: Double, end: Double, easeIn: Double, easeOut: Double,
                focus: CGPoint, scale: Double) {
        self.init(start: start, end: end, easeIn: easeIn, easeOut: easeOut,
                  scale: scale, focusKeys: [FocusKey(time: start, point: focus)])
    }

    public var focus: CGPoint { focusKeys.first?.point ?? CGPoint(x: 0.5, y: 0.5) }

    /// Maps every time-domain value into a retimed composition (factor = 1/speed). Magnification
    /// and focus geometry are untouched.
    public func scaled(by factor: Double) -> ZoomSegment {
        ZoomSegment(start: start * factor, end: end * factor,
                    easeIn: easeIn * factor, easeOut: easeOut * factor,
                    scale: scale,
                    focusKeys: focusKeys.map { FocusKey(time: $0.time * factor, point: $0.point) })
    }
}

/// A persisted, user-editable zoom on the timeline. Auto-generated ones are seeded from clicks
/// (`manual == false`); anything the user creates or edits is `manual == true`, which protects it
/// from click-based regeneration. Maps 1:1 to a `ZoomSegment` for rendering.
public struct ZoomSpec: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    public var easeIn: Double
    public var easeOut: Double
    public var focus: CGPoint
    public var scale: Double
    public var manual: Bool
    /// Optional pan track. `nil`/empty = static `focus`; multiple keys = an auto-generated pan.
    /// Additive: specs persisted before panning existed decode this as `nil`.
    public var focusKeys: [FocusKey]?

    public init(id: String, start: Double, end: Double, easeIn: Double, easeOut: Double,
                focus: CGPoint, scale: Double, manual: Bool, focusKeys: [FocusKey]? = nil) {
        self.id = id; self.start = start; self.end = end
        self.easeIn = easeIn; self.easeOut = easeOut
        self.focus = focus; self.scale = scale; self.manual = manual; self.focusKeys = focusKeys
    }

    public var segment: ZoomSegment {
        if let keys = focusKeys, !keys.isEmpty {
            return ZoomSegment(start: start, end: end, easeIn: easeIn, easeOut: easeOut,
                               scale: scale, focusKeys: keys)
        }
        return ZoomSegment(start: start, end: end, easeIn: easeIn, easeOut: easeOut,
                           focus: focus, scale: scale)
    }
}

/// The evaluated zoom for one instant: `scale` (1 = no zoom) about `focus` (normalized, top-left).
/// `progress` is the eased 0…1 envelope (0 = out, 1 = fully zoomed) — used to shrink the webcam in
/// step with the zoom.
public struct ZoomState: Equatable, Sendable {
    public var scale: Double
    public var focus: CGPoint
    public var progress: Double
    public init(scale: Double, focus: CGPoint, progress: Double = 0) {
        self.scale = scale; self.focus = focus; self.progress = progress
    }
    public static let identity = ZoomState(scale: 1, focus: CGPoint(x: 0.5, y: 0.5), progress: 0)
}

public enum AutoZoom {
    static let chainGap = 3.5          // clicks within this many seconds of the last one chain
    static let postClickHold = 1.3     // wait this long after the last click before easing out
    static let panMargin: CGFloat = 0.85 // a click within this fraction of the viewport stays in view

    /// Deterministically turns clicks into non-overlapping zoom segments. Empty when disabled or
    /// when there are no clicks.
    ///
    /// A burst of clicks (chained within `chainGap`) becomes ONE held zoom that *pans*: the zoom-in
    /// completes as the first click lands, then the focus stays put while clicks land inside the
    /// current viewport and only glides ("pans") to a new click when that click falls outside the
    /// viewport — so the view stays magnified and moves to follow you instead of zooming out and back
    /// in on every click. Holds `postClickHold` after the last click, then eases out.
    public static func segments(clicks: [ClickEvent], settings: AutoZoomSettings) -> [ZoomSegment] {
        guard settings.enabled, !clicks.isEmpty else { return [] }
        let level = min(max(settings.level, 1.5), 3.0)
        let speed = min(max(settings.speed, 0), 1)
        let leadIn = lerp(1.3, 0.7, speed)   // ~1s anticipation window at the default speed
        let easeOut = lerp(0.8, 0.4, speed)
        let half = CGFloat(0.5 / level)      // half-extent of the viewport in normalized coords

        let sorted = clicks.sorted { $0.time < $1.time }
        var clusters: [[ClickEvent]] = []
        for c in sorted {
            if var last = clusters.last, let lastT = last.last?.time, c.time - lastT <= chainGap {
                last.append(c)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([c])
            }
        }

        var segments = clusters.map { cluster -> ZoomSegment in
            let firstT = cluster.first!.time
            let lastT = cluster.last!.time
            // Pan keyframes: keep the current focus while clicks land within the viewport; re-centre
            // on a click only when it falls outside (with a small margin).
            var focus = clampFocus(cluster[0].point, half: half)
            var keys = [FocusKey(time: firstT, point: focus)]
            for c in cluster.dropFirst() {
                let inView = abs(c.point.x - focus.x) <= half * panMargin
                    && abs(c.point.y - focus.y) <= half * panMargin
                if !inView {
                    let nf = clampFocus(c.point, half: half)
                    if hypot(nf.x - focus.x, nf.y - focus.y) > 0.01 {
                        focus = nf
                        keys.append(FocusKey(time: c.time, point: focus))
                    }
                }
            }
            let start = max(0, firstT - leadIn)
            let easeIn = firstT - start          // fully zoomed exactly at the first click
            let end = lastT + postClickHold + easeOut
            return ZoomSegment(start: start, end: end, easeIn: easeIn, easeOut: easeOut,
                               scale: level, focusKeys: keys)
        }

        // Keep segments non-overlapping so the evaluator's "first active" pick is unambiguous.
        for i in 0..<max(0, segments.count - 1) where segments[i].end > segments[i + 1].start {
            segments[i].end = max(segments[i].start, segments[i + 1].start)
        }
        return segments
    }

    /// Clamps a focus so its `1/scale` viewport stays fully within the frame (no empty edges).
    static func clampFocus(_ p: CGPoint, half: CGFloat) -> CGPoint {
        CGPoint(x: min(max(p.x, half), 1 - half), y: min(max(p.y, half), 1 - half))
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

public enum ZoomTimeline {
    /// One-pole low-pass time constant for cursor-follow pans. Heavy smoothing is what makes the
    /// motion read as a camera operator, not a jitterbug (Screen Charm ships ~this feel).
    static let panTau = 0.35

    /// The zoom to apply at composition time `t`. Segments are non-overlapping and time-ordered.
    public static func state(at t: Double, segments: [ZoomSegment]) -> ZoomState {
        guard let s = segments.first(where: { t >= $0.start && t < $0.end }) else { return .identity }
        let f = envelope(t, s)
        return ZoomState(scale: 1 + (s.scale - 1) * f, focus: focus(at: t, keys: s.focusKeys),
                         progress: f)
    }

    /// Critically damped spring step response: quadratic start (zero velocity at 0), exponential
    /// settle, mathematically incapable of overshoot. Reaches ~0.995 of the range at `settle`.
    static func springStep(_ t: Double, settle d: Double) -> Double {
        guard t > 0 else { return 0 }
        guard d > 1e-6 else { return 1 }
        let x = 7.5 / d * t // ω·d = 7.5 ⇒ p(d) ≈ 0.995
        return 1 - (1 + x) * exp(-x)
    }

    /// Spring in from the start, spring out toward the end; `min` composes the two so short
    /// segments stay continuous (they simply never reach a full hold).
    static func envelope(_ t: Double, _ s: ZoomSegment) -> Double {
        guard t >= s.start, t < s.end else { return 0 }
        return min(springStep(t - s.start, settle: max(s.easeIn, 0.15)),
                   springStep(s.end - t, settle: max(s.easeOut, 0.15)))
    }

    /// Focus at `t`: the key points are step targets; the camera runs them through a one-pole
    /// low-pass filter (closed form, piecewise-exponential — deterministic, so preview and export
    /// agree exactly). Before the first key the focus is pinned to it: the zoom-in grows toward
    /// the first click and never pans while easing.
    static func focus(at t: Double, keys: [FocusKey]) -> CGPoint {
        guard var target = keys.first?.point else { return CGPoint(x: 0.5, y: 0.5) }
        guard keys.count > 1, t > keys[0].time else { return target }
        var pos = target
        var clock = keys[0].time
        for key in keys.dropFirst() where key.time < t {
            pos = decay(pos, toward: target, over: key.time - clock)
            target = key.point
            clock = key.time
        }
        return decay(pos, toward: target, over: t - clock)
    }

    /// Exponential approach: after `dt` seconds the remaining distance to `target` shrinks by
    /// `e^(-dt/panTau)`. Monotone per axis — the pan can slow down but never overshoot or bounce.
    static func decay(_ p: CGPoint, toward target: CGPoint, over dt: Double) -> CGPoint {
        guard dt > 0 else { return p }
        let a = 1 - exp(-dt / panTau)
        return CGPoint(x: p.x + (target.x - p.x) * a, y: p.y + (target.y - p.y) * a)
    }
}
