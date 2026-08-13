import CoreImage
import XCTest
@testable import RenderCore

final class CompositorWebcamTests: XCTestCase {
    func screen() -> CIImage {
        CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.9))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
    }
    /// Landscape webcam frame: red with a green center square (proves center-crop, not squish).
    func webcam() -> CIImage {
        let base = CIImage(color: CIColor(red: 0.9, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        let center = CIImage(color: CIColor(red: 0.1, green: 0.8, blue: 0.2))
            .cropped(to: CGRect(x: 60, y: 25, width: 40, height: 40))
        return center.composited(over: base)
    }

    func testCircleBubbleGolden() throws {
        var s = RenderSettings.default // roundness 1, bottom-right
        s.background = .solid(RGBAColor(r: 0.95, g: 0.9, b: 0.82))
        s.webcam.size = 0.24 // pin the golden independent of the tunable default size
        let out = Compositor().render(
            RenderInputs(screen: screen(), webcam: webcam()),
            settings: s, canvasSize: CGSize(width: 400, height: 260))
        try GoldenAssert.compare(out, name: "webcam_circle")
    }

    func testRoundedRectBubbleGolden() throws {
        var s = RenderSettings.default
        s.background = .solid(RGBAColor(r: 0.95, g: 0.9, b: 0.82))
        s.webcam.size = 0.24 // pin the golden independent of the tunable default size
        s.webcam.roundness = 0.25
        s.webcam.center = CGPoint(x: 0.15, y: 0.8) // bottom-left
        let out = Compositor().render(
            RenderInputs(screen: screen(), webcam: webcam()),
            settings: s, canvasSize: CGSize(width: 400, height: 260))
        try GoldenAssert.compare(out, name: "webcam_roundedrect")
    }

    func testHiddenWebcamMatchesCanvasOnly() throws {
        var s = RenderSettings.default
        s.background = .solid(RGBAColor(r: 0.95, g: 0.9, b: 0.82))
        s.webcam.visible = false
        let with = Compositor().render(RenderInputs(screen: screen(), webcam: webcam()),
                                       settings: s, canvasSize: CGSize(width: 400, height: 260))
        let without = Compositor().render(RenderInputs(screen: screen()),
                                          settings: s, canvasSize: CGSize(width: 400, height: 260))
        XCTAssertLessThan(GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(with),
                                                   GoldenAssert.cgImage(without)), 0.001)
    }
}

extension CompositorWebcamTests {
    /// The bubble shadow must be the squircle's local soft silhouette: no smeared bars
    /// sticking out of the bubble's sides, no sharp cutoff edge where the shadow's crop
    /// ends. Renders the same scene with and without shadow; beside the bubble (in the
    /// old artifact band) the two must match, while below the bubble the shadow must
    /// actually darken the canvas.
    func testBubbleShadowStaysSoftAndLocal() throws {
        var s = RenderSettings.default
        s.background = .solid(RGBAColor(r: 0.95, g: 0.95, b: 0.95))
        s.webcam.size = 0.5
        s.webcam.center = CGPoint(x: 0.5, y: 0.5)
        s.shadow = ShadowSettings(opacity: 1, radius: 0.03, offsetY: 0.012)
        var noShadow = s
        noShadow.shadow.opacity = 0

        let canvas = CGSize(width: 400, height: 260)
        let inputs = RenderInputs(screen: screen(), webcam: webcam())
        let with = GoldenAssert.cgImage(Compositor().render(inputs, settings: s, canvasSize: canvas))
        let without = GoldenAssert.cgImage(Compositor().render(inputs, settings: noShadow, canvasSize: canvas))

        // Bubble rect (canvas coords, y-up): side = 0.5 * 260 = 130, centered → x 135–265, y 65–195.
        // σ = 130 * 0.045 ≈ 5.85; the old clamped-edge bars ran from the side midpoints out to a
        // hard crop edge ≈ 23 px past the bubble. Sample inside that band, ~3.4σ from the edge,
        // where a correct gaussian tail is ≈ 0.
        for (x, y) in [(285, 130), (115, 130)] {
            let d = pixelDiff(with, without, x: x, y: y, canvasHeight: Int(canvas.height))
            XCTAssertLessThan(d, 0.02, "shadow bar leaked beside the bubble at (\(x), \(y))")
        }
        // Below the bubble (shadow offsets downward) the shadow must be present.
        let below = pixelDiff(with, without, x: 200, y: 56, canvasHeight: Int(canvas.height))
        XCTAssertGreaterThan(below, 0.05, "expected a visible shadow below the bubble")
    }

    /// Mean channel difference (0–1) between the two images at one point, given in
    /// canvas (y-up) coordinates.
    private func pixelDiff(_ a: CGImage, _ b: CGImage, x: Int, y: Int, canvasHeight: Int) -> Double {
        func rgba(_ img: CGImage, _ px: Int, _ py: Int) -> [Double] {
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: -px, y: -(img.height - 1 - py), width: img.width, height: img.height))
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<3).map { Double(p[$0]) / 255 }
        }
        let py = canvasHeight - 1 - y // canvas y-up → CG row from top
        let ca = rgba(a, x, py), cb = rgba(b, x, py)
        return zip(ca, cb).map { abs($0 - $1) }.reduce(0, +) / 3
    }
}
