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

    public init(id: String, start: Double, end: Double, rect: CGRect) {
        self.id = id
        self.start = start
        self.end = end
        self.rect = rect
    }

    /// Maps the time span into a retimed composition (factor = 1/speed). Geometry is untouched.
    public func scaled(by factor: Double) -> BlurBoxSpec {
        BlurBoxSpec(id: id, start: start * factor, end: end * factor, rect: rect)
    }

    /// The regions to blur on the frame at `t` (boundary-inclusive).
    public static func activeRects(_ boxes: [BlurBoxSpec], at t: Double) -> [CGRect] {
        boxes.filter { $0.start <= t && t <= $0.end }.map(\.rect)
    }
}
