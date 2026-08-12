import CoreGraphics
import CoreImage

/// A recorded pointer position at a point in time (normalized screen coords, top-left origin).
/// `cursorType` is the pointer shape at that moment ("arrow", "pointingHand", …) when the
/// recording captured it; `nil` = unknown → drawn as an arrow.
public struct CursorSample: Sendable, Equatable {
    public var time: Double
    public var point: CGPoint
    public var cursorType: String?
    public init(time: Double, point: CGPoint, cursorType: String? = nil) {
        (self.time, self.point, self.cursorType) = (time, point, cursorType)
    }
}

/// What the compositor needs to draw the pointer for one frame: the image, the pointer position
/// (normalized screen, top-left), and its size as a fraction of canvas height (before zoom).
public struct CursorFrame {
    public var image: CIImage
    public var point: CGPoint
    public var sizeFraction: Double
    public init(image: CIImage, point: CGPoint, sizeFraction: Double) {
        self.image = image; self.point = point; self.sizeFraction = sizeFraction
    }
}

public enum CursorTrack {
    /// Nearest-preceding sample at time `t` (holds the last known position). Samples must be
    /// time-ordered. Returns nil only when there are no samples.
    public static func sample(at t: Double, samples: [CursorSample]) -> CursorSample? {
        guard let first = samples.first else { return nil }
        if t <= first.time { return first }
        var lo = 0, hi = samples.count - 1, idx = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if samples[mid].time <= t { idx = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return samples[idx]
    }

    /// Nearest-preceding pointer position at time `t`.
    public static func point(at t: Double, samples: [CursorSample]) -> CGPoint? {
        sample(at: t, samples: samples)?.point
    }
}

/// The click "haptic": the pointer shrinks quickly on mouse-down and springs back — a visual
/// stand-in for the physical press. Deterministic, so preview and export agree.
public enum CursorPulse {
    public static let press = 0.09   // seconds to shrink after a click
    public static let release = 0.28 // seconds to spring back
    public static let depth = 0.82   // scale at the bottom of the press

    /// Cursor scale factor at time `t` (1 = rest). `clicks` are time-ordered mouse-down times.
    public static func scale(at t: Double, clicks: [Double]) -> Double {
        guard let c = clicks.last(where: { $0 <= t && t - $0 <= press + release }) else { return 1 }
        let dt = t - c
        if dt < press { return 1 - (1 - depth) * smooth(dt / press) }
        return depth + (1 - depth) * smooth((dt - press) / release)
    }

    private static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
