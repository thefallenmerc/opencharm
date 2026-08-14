import CoreGraphics
import CoreImage

/// The synthetic pointer's visuals: the arrow art (and an optional distinct hand art for
/// "pointingHand" samples), plus where each image's HOTSPOT sits — the point that should land on
/// the recorded pointer position, normalized 0…1 within the art with a top-left origin.
///
/// `(0, 0)` is the art's top-left corner (today's only behavior: the tip sits there), `(0.5, 0.5)`
/// is the art's center (e.g. a halo ring drawn around the pointer). `Compositor.drawCursor` reads
/// this to anchor the art; everything else about drawing (scale, drop shadow, click pulse) stays
/// unchanged.
public struct CursorArt: Sendable {
    public var arrow: CIImage
    /// `nil` = `arrow` is also used for "pointingHand" samples (no distinct hand art).
    public var hand: CIImage?
    public var hotspot: CGPoint
    public var handHotspot: CGPoint

    public init(arrow: CIImage, hand: CIImage? = nil, hotspot: CGPoint = .zero,
               handHotspot: CGPoint = .zero) {
        self.arrow = arrow
        self.hand = hand
        self.hotspot = hotspot
        self.handHotspot = handHotspot
    }
}
