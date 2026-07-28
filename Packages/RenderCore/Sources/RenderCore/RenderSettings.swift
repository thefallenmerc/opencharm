import CoreGraphics
import Foundation

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
    public init(visible: Bool, center: CGPoint, size: Double, roundness: Double) {
        (self.visible, self.center, self.size, self.roundness) = (visible, center, size, roundness)
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

    public init(background: Background, paddingFraction: Double, cornerRadiusFraction: Double,
                shadow: ShadowSettings, webcam: WebcamSettings) {
        self.background = background
        self.paddingFraction = paddingFraction
        self.cornerRadiusFraction = cornerRadiusFraction
        self.shadow = shadow
        self.webcam = webcam
    }

    public static let `default` = RenderSettings(
        background: .linearGradient(
            start: RGBAColor(r: 0.28, g: 0.18, b: 0.55),
            end: RGBAColor(r: 0.10, g: 0.35, b: 0.60),
            angleDegrees: 35),
        paddingFraction: 0.06,
        cornerRadiusFraction: 0.02,
        shadow: ShadowSettings(opacity: 0.45, radius: 0.03, offsetY: 0.012),
        webcam: WebcamSettings(visible: true, center: CGPoint(x: 0.87, y: 0.82),
                               size: 0.24, roundness: 1.0))
}
