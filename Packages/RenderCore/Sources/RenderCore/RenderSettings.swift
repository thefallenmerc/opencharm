import CoreGraphics

public struct RGBAColor: Codable, Equatable, Sendable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }
}

public enum Background: Codable, Equatable, Sendable {
    case solid(RGBAColor)
    case linearGradient(start: RGBAColor, end: RGBAColor, angleDegrees: Double)
    /// "preset:<name>" refers to a bundled asset; anything else is an absolute file path.
    case image(path: String)
}

public struct ShadowSettings: Codable, Equatable, Sendable {
    /// 0–1. Radius/offset are fractions of canvas min dimension so they scale with export size.
    public var opacity: Double
    public var radius: Double
    public var offsetY: Double
    public init(opacity: Double, radius: Double, offsetY: Double) {
        (self.opacity, self.radius, self.offsetY) = (opacity, radius, offsetY)
    }
}

public struct WebcamSettings: Codable, Equatable, Sendable {
    public var visible: Bool
    /// Normalized 0–1 canvas coords, y = 0 at the TOP (UI convention).
    public var center: CGPoint
    /// Bubble side as a fraction of canvas min dimension. Bubble is square.
    public var size: Double
    /// 0 = square-ish rounded rect, 1 = circle. cornerRadius = roundness * side/2.
    public var roundness: Double
    /// Crop-zoom inside the bubble (1–2): 2 shows the center half of the webcam frame — a tighter
    /// face framing. Additive/optional: `nil` = 1 (no crop).
    public var contentZoom: Double?
    public init(visible: Bool, center: CGPoint, size: Double, roundness: Double,
                contentZoom: Double? = nil) {
        (self.visible, self.center, self.size, self.roundness) = (visible, center, size, roundness)
        self.contentZoom = contentZoom
    }
}

/// Output canvas aspect. `auto` matches the recording; presets extend the canvas on one axis
/// (never cropping content — `CanvasLayout` already fits the screen inside whatever canvas it gets).
public enum AspectPreset: String, Codable, CaseIterable, Sendable {
    case auto, wide16x9, classic4x3, square, vertical9x16

    public var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .wide16x9: 16.0 / 9.0
        case .classic4x3: 4.0 / 3.0
        case .square: 1
        case .vertical9x16: 9.0 / 16.0
        }
    }

    /// Canvas for a given source (screen) size: keeps the axis that already fills the preset and
    /// extends the other, rounded down to even pixels (codec requirement).
    public func canvasSize(for source: CGSize) -> CGSize {
        guard let ratio else { return source }
        func even(_ v: CGFloat) -> CGFloat {
            let f = v.rounded(.down)
            return f - f.truncatingRemainder(dividingBy: 2)
        }
        let sourceAspect = source.width / source.height
        if ratio >= sourceAspect {
            return CGSize(width: even(source.height * ratio), height: even(source.height))
        }
        return CGSize(width: even(source.width), height: even(source.width / ratio))
    }
}

public struct RenderSettings: Codable, Equatable, Sendable {
    public var background: Background
    /// Inset around the screen content, fraction of canvas min dimension. 0–0.25.
    public var paddingFraction: Double
    /// Screen-content corner radius, fraction of content min dimension. 0–0.2.
    public var cornerRadiusFraction: Double
    public var shadow: ShadowSettings
    public var webcam: WebcamSettings
    /// Auto zoom-on-click. Optional/additive: manifests written before this feature decode `nil`,
    /// which consumers treat as `AutoZoomSettings.default` (disabled).
    public var autoZoom: AutoZoomSettings?
    /// The materialized, editable timeline zooms. `nil` = not yet seeded (the Studio seeds it from
    /// clicks on first open); once set, it is the source of truth for rendering. Additive/optional.
    public var zooms: [ZoomSpec]?
    /// Trim in/out points in composition seconds. `nil` = no trim on that side.
    public var trimStart: Double?
    public var trimEnd: Double?
    /// Synthetic-pointer height as a fraction of canvas height (before zoom magnification). `nil` =
    /// the default. Only used when the recording hid the system cursor.
    public var cursorSize: Double?
    /// Output canvas aspect preset. Additive/optional: `nil` = `.auto` (match the recording).
    public var aspect: AspectPreset?
    /// Global playback speed (0.5–2). Preview plays at this rate; export retimes the composition.
    /// Additive/optional: `nil` = 1 (real time).
    public var playbackSpeed: Double?
    /// Background softening, 0–1 (maps to a Gaussian sigma of 4% of the canvas min dimension at 1).
    /// Additive/optional: `nil` = 0 (sharp).
    public var backgroundBlur: Double?
    /// Split points on the timeline (original-composition seconds) — segment boundaries the user
    /// created with Cut. Additive/optional.
    public var splits: [Double]?
    /// Deleted segments (original-composition seconds). Preview skips them; export removes them.
    /// Additive/optional.
    public var cuts: [CutRange]?

    public init(background: Background, paddingFraction: Double, cornerRadiusFraction: Double,
                shadow: ShadowSettings, webcam: WebcamSettings,
                autoZoom: AutoZoomSettings? = nil,
                zooms: [ZoomSpec]? = nil, trimStart: Double? = nil, trimEnd: Double? = nil,
                cursorSize: Double? = nil, aspect: AspectPreset? = nil,
                playbackSpeed: Double? = nil, backgroundBlur: Double? = nil,
                splits: [Double]? = nil, cuts: [CutRange]? = nil) {
        self.background = background
        self.paddingFraction = paddingFraction
        self.cornerRadiusFraction = cornerRadiusFraction
        self.shadow = shadow
        self.webcam = webcam
        self.autoZoom = autoZoom
        self.zooms = zooms
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.cursorSize = cursorSize
        self.aspect = aspect
        self.playbackSpeed = playbackSpeed
        self.backgroundBlur = backgroundBlur
        self.splits = splits
        self.cuts = cuts
    }

    public static let `default` = RenderSettings(
        background: .linearGradient(
            start: RGBAColor(r: 0.28, g: 0.18, b: 0.55),
            end: RGBAColor(r: 0.10, g: 0.35, b: 0.60),
            angleDegrees: 35),
        paddingFraction: 0.06,
        cornerRadiusFraction: 0.02,
        shadow: ShadowSettings(opacity: 0.45, radius: 0.03, offsetY: 0.012),
        // Squircle bubble (icon-like continuous corners, not a circle), 1.2× the old default size.
        webcam: WebcamSettings(visible: true, center: CGPoint(x: 0.87, y: 0.82),
                               size: 0.29, roundness: 0.65),
        autoZoom: .default)
}
