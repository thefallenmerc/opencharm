import CoreGraphics

/// The camera's instantaneous rate of change: how fast the zoom viewport is panning and how fast
/// it is scaling, at one point in time. Feeds the cinematic motion-blur filters in
/// `Compositor.motionBlurred` — directional blur for pans, zoom blur for scale ramps.
public struct CameraVelocity: Equatable, Sendable {
    /// Normalized content-space (0…1, top-left origin) units per second the zoom focus is
    /// panning at.
    public var focusRate: CGVector
    /// Zoom `scale` change per second (e.g. going from 1× to 2× over one second is `1`).
    public var scaleRate: Double

    public init(focusRate: CGVector, scaleRate: Double) {
        self.focusRate = focusRate
        self.scaleRate = scaleRate
    }

    public static let zero = CameraVelocity(focusRate: .zero, scaleRate: 0)

    /// Finite difference between two `ZoomState`s `dt` seconds apart — deterministic and stateless
    /// (a pure function of two evaluator samples), so it stays safe under AVFoundation's
    /// out-of-order concurrent frame rendering: no incrementally-accumulated "last frame" state to
    /// race on. `dt <= 0` is degenerate (nothing to divide by) and returns `.zero`.
    public static func between(_ a: ZoomState, _ b: ZoomState, dt: Double) -> CameraVelocity {
        guard dt > 0 else { return .zero }
        let focusRate = CGVector(dx: (b.focus.x - a.focus.x) / CGFloat(dt),
                                 dy: (b.focus.y - a.focus.y) / CGFloat(dt))
        let scaleRate = (b.scale - a.scale) / dt
        return CameraVelocity(focusRate: focusRate, scaleRate: scaleRate)
    }

    /// Half-width of the central finite difference `sampled` takes: half a frame at 60 fps, so the
    /// two probes straddle `t` inside its own frame at every export rate this app produces.
    public static let sampleEps = 1.0 / 120

    /// The camera velocity at `t`, sampled straight from the stateless `ZoomTimeline` evaluator —
    /// the one entry point the render path uses, so preview and export can never drift apart.
    ///
    /// The pan component is only taken when BOTH probes land inside the SAME zoom segment.
    /// `ZoomTimeline.state`'s focus is discontinuous at every segment edge: outside a zoom it is
    /// the canvas centre, and one instant inside it is the segment's anchor. A difference that
    /// straddles an edge therefore reports a focus rate of tens of units per second and pins
    /// `CIMotionBlur` at its radius cap for exactly one frame — a smear flash at the start and end
    /// of every zoom, in preview and export alike. That jump is not motion: at an edge the
    /// envelope is 0, so the scale is 1 and `zoomedCanvas` moves no pixel at all for ANY focus.
    /// Two touching segments hit the same trap with two different anchors, which is why the test
    /// is "same segment", not merely "zoomed at both probes".
    ///
    /// `scale` is continuous across an edge (`1 + (scale - 1) * envelope`, and the envelope goes to
    /// 0 there), so the scale rate is always kept — it is exactly what makes a zoom-in blur.
    public static func sampled(at t: Double, segments: [ZoomSegment],
                               cursorTrack: [CursorSample] = [],
                               eps: Double = CameraVelocity.sampleEps) -> CameraVelocity {
        let prev = ZoomTimeline.state(at: t - eps, segments: segments, cursorTrack: cursorTrack)
        let next = ZoomTimeline.state(at: t + eps, segments: segments, cursorTrack: cursorTrack)
        let v = between(prev, next, dt: 2 * eps)
        let iPrev = ZoomTimeline.activeSegmentIndex(at: t - eps, segments: segments)
        let iNext = ZoomTimeline.activeSegmentIndex(at: t + eps, segments: segments)
        guard iPrev != nil, iPrev == iNext else {
            return CameraVelocity(focusRate: .zero, scaleRate: v.scaleRate)
        }
        return v
    }
}
