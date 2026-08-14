import CoreGraphics
import CoreImage
import Foundation

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
    /// Where in `image` the pointer position lands, normalized 0…1 top-left origin. `.zero`
    /// (the default) reproduces the pre-hotspot behavior: the art's top-left corner is the tip.
    public var hotspot: CGPoint
    public init(image: CIImage, point: CGPoint, sizeFraction: Double, hotspot: CGPoint = .zero) {
        self.image = image; self.point = point; self.sizeFraction = sizeFraction
        self.hotspot = hotspot
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

    /// Smoothed pointer velocity at `t`, in normalized content units per second (top-left origin,
    /// so `dy > 0` means the pointer is moving DOWN the screen).
    ///
    /// Deterministic closed-form replay: the filter starts at rest `horizon` seconds before `t`
    /// and folds each recorded sample pair's finite difference through a one-pole low-pass with
    /// time constant `tau`. It keeps NO state between calls — frames render out of order on
    /// AVFoundation's concurrent queue, so the same `t` must always yield the same vector
    /// regardless of what was queried before. Same stateless-replay pattern as
    /// `ZoomTimeline.followedFocus`; cost is O(samples in the window).
    ///
    /// Returns `.zero` when the window `[t - horizon, t]` holds fewer than two samples — i.e. the
    /// pointer has demonstrably been at rest for longer than the horizon.
    public static func velocity(at t: Double, samples: [CursorSample],
                                tau: Double = 0.25, horizon: Double = 2.0) -> CGVector {
        guard samples.count > 1, tau > 0 else { return .zero }
        let start = lowerBound(samples, time: t - horizon)
        guard start < samples.count, samples[start].time <= t else { return .zero }

        var vx = 0.0, vy = 0.0
        var last = samples[start].time
        var i = start
        while i + 1 < samples.count, samples[i + 1].time <= t {
            let (a, b) = (samples[i], samples[i + 1])
            let dt = b.time - a.time
            i += 1
            guard dt > 0 else { continue } // duplicate timestamps carry no motion
            last = b.time
            // Instantaneous finite difference, with the interval floored at one 240 Hz tick so a
            // pair of near-simultaneous samples cannot explode into a spike.
            let step = max(dt, 1.0 / 240)
            let rawX = Double(b.point.x - a.point.x) / step
            let rawY = Double(b.point.y - a.point.y) / step
            let alpha = 1 - exp(-dt / tau)
            vx += (rawX - vx) * alpha
            vy += (rawY - vy) * alpha
        }
        // Past the last sample the pointer is, by definition, not moving: coast to rest with the
        // same time constant instead of holding the last velocity forever.
        if t > last {
            let decay = exp(-(t - last) / tau)
            vx *= decay
            vy *= decay
        }
        return CGVector(dx: vx, dy: vy)
    }

    /// Index of the first sample at or after `time` (`samples.count` if there is none).
    /// Mirrors the binary search in `sample(at:)`, as a lower bound rather than an upper one.
    private static func lowerBound(_ samples: [CursorSample], time: Double) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
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
