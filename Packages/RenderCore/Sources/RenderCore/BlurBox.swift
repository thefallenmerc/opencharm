import CoreGraphics
import Foundation

/// A timeline-scoped privacy mask: between `start` and `end` the region `rect` of the screen
/// content is blurred beyond legibility — for hiding passwords, accounts, or anything else
/// sensitive without external tools. Persisted in `RenderSettings.blurBoxes`.
public struct BlurBoxSpec: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Composition seconds (same clock as track offsets / zooms).
    public var start: Double
    public var end: Double
    /// Region to blur, normalized over the screen CONTENT (0…1, top-left origin — the same
    /// space as zoom focus points), so it tracks the content through padding/aspect/zoom.
    public var rect: CGRect
    /// Fraction of the box's min pixel side, 0…0.5. Additive/optional: `nil` = legacy `0.15`.
    public var cornerRadius: Double?
    /// Blur strength, 0…1. Additive/optional: `nil` = 0.5 = legacy auto sigma.
    public var intensity: Double?

    public init(id: String, start: Double, end: Double, rect: CGRect,
                cornerRadius: Double? = nil, intensity: Double? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.intensity = intensity
    }

    /// Maps the time span into a retimed composition (factor = 1/speed). Geometry/style untouched.
    public func scaled(by factor: Double) -> BlurBoxSpec {
        BlurBoxSpec(id: id, start: start * factor, end: end * factor, rect: rect,
                    cornerRadius: cornerRadius, intensity: intensity)
    }

    /// The boxes to blur on the frame at `t` (boundary-inclusive).
    public static func active(_ boxes: [BlurBoxSpec], at t: Double) -> [BlurBoxSpec] {
        boxes.filter { $0.start <= t && t <= $0.end }
    }
}
