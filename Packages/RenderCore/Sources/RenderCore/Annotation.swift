import CoreGraphics

/// `RGBAColor.cgColor` — a CoreGraphics color built from the same 0…1 components used
/// throughout `RenderSettings`, for the CGContext-based sprite rasterizers in
/// `Compositor+Annotations`. RenderCore stays AppKit-free: this is plain CoreGraphics.
public extension RGBAColor {
    var cgColor: CGColor {
        CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}

/// A timeline-scoped drawn annotation — text, a shape, an arrow, or a spotlight — composited
/// over the screen content between `start` and `end`. Stackable: array order is z-order (later
/// entries draw on top). Persisted in `RenderSettings.annotations`.
public struct AnnotationSpec: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, CaseIterable, Sendable {
        case text, rectangle, ellipse, arrow, spotlight
    }

    public var id: String
    /// Raw string so unknown kinds from future versions round-trip unchanged; the renderer
    /// skips anything it doesn't recognize instead of failing to decode.
    public var kind: String
    public var resolvedKind: Kind? { Kind(rawValue: kind) }
    /// Composition seconds (same clock as track offsets / zooms / blur boxes).
    public var start: Double
    public var end: Double
    /// Normalized content space 0…1, top-left origin (same space as `BlurBoxSpec.rect` / zoom
    /// focus). For arrows this is the bounding box of the endpoints (chrome/hit only — the
    /// actual geometry is `arrowStart`/`arrowEnd`).
    public var rect: CGRect

    // Optional per-kind fields; nil = default. Sizes are fractions of content dims so they
    // scale with export size, matching `BlurBoxSpec`'s additive-optional style convention.
    /// Stroke/text color. Default (when nil): a red-ish accent.
    public var color: RGBAColor?
    /// Fraction of the content's min dimension. Default: 0.006.
    public var strokeWidth: Double?
    /// Rectangle + spotlight hole corner radius, fraction of the shape's min pixel side.
    /// Default: 0.15.
    public var cornerRadius: Double?
    /// Rectangle/ellipse fill, 0…1. Default: 0 (outline only).
    public var fillOpacity: Double?
    public var text: String?
    /// Fraction of content height. Default: 0.045.
    public var fontSize: Double?
    /// Content-normalized endpoints. Default (when nil): derived from `rect`'s left/right
    /// mid-points.
    public var arrowStart: CGPoint?
    public var arrowEnd: CGPoint?
    /// Spotlight backdrop dim, 0…1. Default: 0.55.
    public var dimOpacity: Double?

    public init(id: String, kind: String, start: Double, end: Double, rect: CGRect,
                color: RGBAColor? = nil, strokeWidth: Double? = nil, cornerRadius: Double? = nil,
                fillOpacity: Double? = nil, text: String? = nil, fontSize: Double? = nil,
                arrowStart: CGPoint? = nil, arrowEnd: CGPoint? = nil, dimOpacity: Double? = nil) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.rect = rect
        self.color = color
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.fillOpacity = fillOpacity
        self.text = text
        self.fontSize = fontSize
        self.arrowStart = arrowStart
        self.arrowEnd = arrowEnd
        self.dimOpacity = dimOpacity
    }

    /// Maps the time span into a retimed composition (factor = 1/speed). Geometry/style untouched.
    public func scaled(by factor: Double) -> AnnotationSpec {
        var s = self
        s.start = start * factor
        s.end = end * factor
        return s
    }

    /// The annotations to draw on the frame at `t` (boundary-inclusive), same gating as
    /// `BlurBoxSpec.active`.
    public static func active(_ specs: [AnnotationSpec], at t: Double) -> [AnnotationSpec] {
        specs.filter { $0.start <= t && t <= $0.end }
    }
}
