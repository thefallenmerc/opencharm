import CoreGraphics
import Foundation

/// "3D motion": while a zoom is held, the screen-content card tilts a few degrees in response to
/// how fast the pointer is travelling — the depth cue a 3D map gives when you drag it.
///
/// Additive-optional on `RenderSettings`: `nil` (and `enabled == false`, and `strength == 0`)
/// resolve to `TiltState.identity`, which the compositor answers with its original flat code path,
/// byte for byte. Old projects therefore render exactly as they did before this feature existed.
public struct Motion3DSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// 0…1 — scales the full deflection. 0 is flat.
    public var strength: Double

    public init(enabled: Bool = false, strength: Double = 0.5) {
        self.enabled = enabled
        self.strength = strength
    }

    public static let `default` = Motion3DSettings()
}

/// One frame's tilt of the content card, in radians about the card's own centre axes.
///
/// Sign convention — the canvas is y-up, and an edge "recedes" when it is pushed AWAY from the
/// camera, so perspective pulls it toward the card's centre and shortens it:
///   * `yaw > 0`   ⇐ pointer moving RIGHT ⇒ the RIGHT edge recedes (the left edge advances).
///   * `pitch > 0` ⇐ pointer moving UP    ⇒ the TOP   edge recedes (the bottom edge advances).
/// The card therefore leans away from the direction of travel, the way a map's far side dips
/// under you as you drag it.
public struct TiltState: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double

    public init(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
    }

    public static let identity = TiltState(yaw: 0, pitch: 0)

    /// Below this the warp is a guaranteed sub-pixel no-op at any realistic canvas size, so the
    /// compositor skips the whole tilt pipeline and takes the original flat path instead.
    public var isIdentity: Bool { abs(yaw) < 1e-4 && abs(pitch) < 1e-4 }
}

public enum MotionTilt {
    /// Full deflection at strength 1 and a saturated pointer. Deliberately tiny: past ~5° the
    /// effect stops reading as depth and starts reading as a broken aspect ratio.
    public static let maxRadians = 4.0 * .pi / 180
    /// Normalized content units per second at which the tilt saturates.
    public static let vRef = 1.2
    /// Pinhole camera distance as a multiple of the card's long side. Far enough that 4° of tilt
    /// is a gentle parallax rather than a fisheye.
    public static let distanceFactor: CGFloat = 2.5

    /// The tilt for one frame. Every gate that means "off" returns `.identity`, which is the
    /// compositor's byte-identical fast path — including `zoomProgress == 0`, so the card is only
    /// ever tilted while a zoom is actually engaged, and the tilt fades in and out with it.
    ///
    /// Pure and stateless: a closed-form function of `t` alone, safe on the concurrent render
    /// queue where frames arrive out of order.
    public static func state(at t: Double, samples: [CursorSample],
                             zoomProgress: Double, settings: Motion3DSettings?) -> TiltState {
        guard let s = settings, s.enabled, zoomProgress > 0, s.strength > 0 else { return .identity }
        let v = CursorTrack.velocity(at: t, samples: samples)
        let gain = maxRadians * min(max(s.strength, 0), 1) * min(max(zoomProgress, 0), 1)
        // `v.dy` lives in the recorded, TOP-LEFT-origin normalized space: dy > 0 = moving DOWN.
        // Negating it makes "moving up the screen" a positive pitch, i.e. the top edge recedes.
        return TiltState(yaw: unitClamp(Double(v.dx) / vRef) * gain,
                         pitch: unitClamp(-Double(v.dy) / vRef) * gain)
    }

    /// Projects `rect`'s four corners through `tilt`: yaw about the vertical centre axis, then
    /// pitch about the horizontal centre axis, then a pinhole perspective divide at camera
    /// distance `distanceFactor × max(width, height)`. Input and output share the same y-up canvas
    /// space, so `tl` is the corner at `(minX, maxY)`. An identity tilt returns the exact corners.
    public static func tiltedCorners(rect: CGRect, tilt: TiltState)
        -> (tl: CGPoint, tr: CGPoint, bl: CGPoint, br: CGPoint) {
        project(rect, tilt: tilt, about: CGPoint(x: rect.midX, y: rect.midY),
                distance: cameraDistance(for: rect))
    }

    /// The pinhole camera distance `tiltedCorners` uses for a card of `rect`'s size.
    static func cameraDistance(for rect: CGRect) -> CGFloat {
        distanceFactor * max(rect.width, rect.height)
    }

    /// `tiltedCorners` with an explicitly supplied camera.
    ///
    /// The projection is a homography (both projected coordinates are linear in the card-plane
    /// coordinates over one shared linear denominator), so projecting ANY rect in the card's plane
    /// with the SAME centre and distance yields mutually consistent corners. That is what lets the
    /// compositor warp a PADDED crop of the card — passing the padded rect's projected corners to
    /// `CIPerspectiveTransform`, which maps its input's extent corners — and still have the
    /// content rect land exactly on `tiltedCorners(rect: contentRect, tilt:)`.
    static func project(_ rect: CGRect, tilt: TiltState, about center: CGPoint, distance d: CGFloat)
        -> (tl: CGPoint, tr: CGPoint, bl: CGPoint, br: CGPoint) {
        let corners = (tl: CGPoint(x: rect.minX, y: rect.maxY),
                       tr: CGPoint(x: rect.maxX, y: rect.maxY),
                       bl: CGPoint(x: rect.minX, y: rect.minY),
                       br: CGPoint(x: rect.maxX, y: rect.minY))
        guard d > 0, !tilt.isIdentity else { return corners }
        let (cosYaw, sinYaw) = (cos(tilt.yaw), sin(tilt.yaw))
        let (cosPitch, sinPitch) = (cos(tilt.pitch), sin(tilt.pitch))
        let dd = Double(d)

        func project(_ p: CGPoint) -> CGPoint {
            let u = Double(p.x - center.x), v = Double(p.y - center.y)
            // Yaw about the vertical axis, then pitch about the horizontal one. `z` is depth AWAY
            // from the camera, so the perspective divide is d / (d + z): a corner pushed back
            // (z > 0) shrinks toward the centre, one pulled forward (z < 0) grows away from it.
            let x = u * cosYaw
            let y = v * cosPitch
            let z = u * sinYaw + v * sinPitch
            // The clamp only bites at absurd tilts (a corner at or behind the camera); at the
            // ±4° this feature actually produces, |z| stays under 4% of d.
            let scale = dd / max(dd + z, dd * 0.05)
            return CGPoint(x: center.x + CGFloat(x * scale), y: center.y + CGFloat(y * scale))
        }
        return (project(corners.tl), project(corners.tr), project(corners.bl), project(corners.br))
    }

    private static func unitClamp(_ x: Double) -> Double { min(max(x, -1), 1) }
}
