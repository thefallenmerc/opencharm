import CoreGraphics
import CoreImage

/// A recorded pointer position at a point in time (normalized screen coords, top-left origin).
public struct CursorSample: Sendable, Equatable {
    public var time: Double
    public var point: CGPoint
    public init(time: Double, point: CGPoint) { (self.time, self.point) = (time, point) }
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
    /// Nearest-preceding pointer position at time `t` (holds the last known position). Samples must
    /// be time-ordered. Returns nil only when there are no samples.
    public static func point(at t: Double, samples: [CursorSample]) -> CGPoint? {
        guard let first = samples.first else { return nil }
        if t <= first.time { return first.point }
        var lo = 0, hi = samples.count - 1, idx = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if samples[mid].time <= t { idx = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return samples[idx].point
    }
}
