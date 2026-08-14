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
}
