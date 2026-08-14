import CoreImage
import XCTest
@testable import RenderCore

final class BlurBoxTests: XCTestCase {
    func testActiveGating() {
        let box = BlurBoxSpec(id: "a", start: 1, end: 3,
                              rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        XCTAssertTrue(BlurBoxSpec.active([box], at: 0.5).isEmpty)
        XCTAssertEqual(BlurBoxSpec.active([box], at: 1).count, 1) // boundary inclusive
        XCTAssertEqual(BlurBoxSpec.active([box], at: 2).count, 1)
        XCTAssertEqual(BlurBoxSpec.active([box], at: 3).count, 1)
        XCTAssertTrue(BlurBoxSpec.active([box], at: 3.5).isEmpty)
    }

    func testScaledRetimesOnlyTime() {
        let box = BlurBoxSpec(id: "a", start: 2, end: 4,
                              rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                              cornerRadius: 0.25, intensity: 0.9)
        let s = box.scaled(by: 0.5) // 2× speed
        XCTAssertEqual(s.start, 1, accuracy: 0.0001)
        XCTAssertEqual(s.end, 2, accuracy: 0.0001)
        XCTAssertEqual(s.rect, box.rect)
        XCTAssertEqual(s.cornerRadius, box.cornerRadius)
        XCTAssertEqual(s.intensity, box.intensity)
    }

    func testBlurBoxSpecDecodeWithoutStyleFields() throws {
        // Manifests written before this feature must decode with cornerRadius/intensity == nil.
        let box = BlurBoxSpec(id: "a", start: 0, end: 2,
                              rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        let data = try JSONEncoder().encode(box)
        let decoded = try JSONDecoder().decode(BlurBoxSpec.self, from: data)
        XCTAssertNil(decoded.cornerRadius)
        XCTAssertNil(decoded.intensity)
    }

    func testBlurBoxSpecRoundTripWithStyle() throws {
        let box = BlurBoxSpec(id: "b", start: 0, end: 2,
                              rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                              cornerRadius: 0.3, intensity: 0.8)
        let data = try JSONEncoder().encode(box)
        let decoded = try JSONDecoder().decode(BlurBoxSpec.self, from: data)
        XCTAssertEqual(decoded, box)
    }

    func testSettingsDecodeWithoutBlurBoxes() throws {
        // Manifests written before the feature must decode with blurBoxes == nil.
        let data = try JSONEncoder().encode(RenderSettings.default)
        let decoded = try JSONDecoder().decode(RenderSettings.self, from: data)
        XCTAssertNil(decoded.blurBoxes)
        // And round-trip once boxes exist.
        var s = RenderSettings.default
        s.blurBoxes = [BlurBoxSpec(id: "x", start: 0, end: 2,
                                   rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25))]
        let back = try JSONDecoder().decode(RenderSettings.self,
                                            from: JSONEncoder().encode(s))
        XCTAssertEqual(back.blurBoxes, s.blurBoxes)
    }

    /// Screen with a hard left/right color boundary at its middle: blurring any region that
    /// straddles the boundary must mix the colors there. Shared by the render tests below.
    private var boundaryScreen: CIImage {
        let left = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 160, height: 200))
        let right = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 160, y: 0, width: 160, height: 200))
        return right.composited(over: left.composited(
            over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))))
    }

    private var boundarySettings: RenderSettings {
        var s = RenderSettings.default
        s.background = .solid(RGBAColor(r: 0.95, g: 0.95, b: 0.95))
        s.webcam.visible = false
        s.shadow.opacity = 0
        return s
    }

    private func region(_ img: CGImage, _ r: CGRect) -> CGImage { img.cropping(to: r)! }

    /// The blur must scramble the boxed region and leave everything else pixel-identical.
    func testRenderBlursInsideBoxOnly() {
        let s = boundarySettings
        let screen = boundaryScreen
        let canvas = CGSize(width: 400, height: 260)
        // Box over the center of the content, straddling the color boundary.
        let box = BlurBoxSpec(id: "a", start: 0, end: 1,
                              rect: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))
        let plain = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas))
        let blurred = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, blurBoxes: [box]))

        // Content rect for canvas 400×260, screen 320×200, padding 0.06*260=15.6:
        // fits to height → content ≈ 368.6×230.4 centered. Center of canvas = boundary.
        // Inside the box, hugging the color boundary: must differ (colors mixed by blur).
        let inside = CGRect(x: 185, y: 115, width: 30, height: 30)
        XCTAssertGreaterThan(
            GoldenAssert.meanAbsDiff(region(plain, inside), region(blurred, inside)), 0.02,
            "expected the boxed region to be blurred")
        // Well outside the box (top-left area of the content): identical.
        let outside = CGRect(x: 40, y: 30, width: 40, height: 30)
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(region(plain, outside), region(blurred, outside)), 0.001,
            "blur must not leak outside its box")
        // Beside the box on the same row (the streak-bar failure mode): identical.
        let beside = CGRect(x: 40, y: 115, width: 40, height: 30)
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(region(plain, beside), region(blurred, beside)), 0.001,
            "blur must not smear sideways out of its box")
    }

    /// `nil` cornerRadius/intensity must render byte-identical to explicit 0.15/0.5 (the old
    /// hardcoded values) — old projects must not visibly change when this feature ships.
    func testRenderIdenticalForLegacyDefaults() {
        let s = boundarySettings
        let screen = boundaryScreen
        let canvas = CGSize(width: 400, height: 260)
        let rect = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        let legacy = BlurBoxSpec(id: "a", start: 0, end: 1, rect: rect)
        let explicit = BlurBoxSpec(id: "a", start: 0, end: 1, rect: rect,
                                   cornerRadius: 0.15, intensity: 0.5)

        let legacyImg = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, blurBoxes: [legacy]))
        let explicitImg = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, blurBoxes: [explicit]))

        XCTAssertLessThan(GoldenAssert.meanAbsDiff(legacyImg, explicitImg), 0.001,
                          "nil style fields must reproduce today's render exactly")
    }

    /// Higher intensity must blur more strongly: its render differs more from the unblurred
    /// original inside the box than a lower intensity's does.
    func testIntensityIsMonotonic() {
        let s = boundarySettings
        let screen = boundaryScreen
        let canvas = CGSize(width: 400, height: 260)
        let rect = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        let low = BlurBoxSpec(id: "a", start: 0, end: 1, rect: rect, intensity: 0.2)
        let high = BlurBoxSpec(id: "a", start: 0, end: 1, rect: rect, intensity: 1.0)

        let plain = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas))
        let lowImg = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, blurBoxes: [low]))
        let highImg = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, blurBoxes: [high]))

        let inside = CGRect(x: 185, y: 115, width: 30, height: 30)
        let diffLow = GoldenAssert.meanAbsDiff(region(plain, inside), region(lowImg, inside))
        let diffHigh = GoldenAssert.meanAbsDiff(region(plain, inside), region(highImg, inside))
        XCTAssertGreaterThan(diffHigh, diffLow,
                             "higher intensity should differ more from the unblurred original")
    }
}
