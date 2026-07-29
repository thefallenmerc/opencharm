import CoreImage
import XCTest
@testable import RenderCore

final class CompositorCanvasTests: XCTestCase {
    /// Blue field with a white top-left quadrant marker so orientation bugs show up.
    func syntheticScreen(width: Int = 320, height: Int = 200) -> CIImage {
        let base = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.9))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let marker = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return marker.composited(over: base)
    }

    var settings: RenderSettings {
        var s = RenderSettings.default
        s.webcam.visible = false // webcam layer is Task 5
        return s
    }

    func testSolidBackgroundGolden() throws {
        var s = settings
        s.background = .solid(RGBAColor(r: 0.95, g: 0.9, b: 0.82))
        let out = Compositor().render(RenderInputs(screen: syntheticScreen()),
                                      settings: s, canvasSize: CGSize(width: 400, height: 260))
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 400, height: 260))
        try GoldenAssert.compare(out, name: "canvas_solid")
    }

    func testGradientBackgroundGolden() throws {
        let out = Compositor().render(RenderInputs(screen: syntheticScreen()),
                                      settings: settings, canvasSize: CGSize(width: 400, height: 260))
        try GoldenAssert.compare(out, name: "canvas_gradient")
    }

    func testImageBackgroundGolden() throws {
        var s = settings
        s.background = .image(path: "ignored-caller-resolves")
        let bg = CIImage(color: CIColor(red: 0.1, green: 0.5, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100)) // proves scale-to-fill
        let out = Compositor().render(
            RenderInputs(screen: syntheticScreen(), backgroundImage: bg),
            settings: s, canvasSize: CGSize(width: 400, height: 260))
        try GoldenAssert.compare(out, name: "canvas_image_bg")
    }

    func testZeroShadowAndPadding() throws {
        var s = settings
        s.paddingFraction = 0
        s.cornerRadiusFraction = 0
        s.shadow.opacity = 0
        let out = Compositor().render(RenderInputs(screen: syntheticScreen()),
                                      settings: s, canvasSize: CGSize(width: 320, height: 200))
        try GoldenAssert.compare(out, name: "canvas_bare")
    }

    /// Every alpha byte in the rendered output, sampled via premultipliedLast RGBA8.
    private func alphaBytes(_ image: CIImage) -> [UInt8] {
        let cg = GoldenAssert.cgImage(image)
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &data, width: cg.width, height: cg.height,
                            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 3, to: data.count, by: 4).map { data[$0] }
    }

    /// Output must always be opaque, even when a caller passes a semi-transparent solid
    /// background color — the render contract promises fully-opaque output regardless of input.
    func testOutputIsOpaqueWithSemiTransparentSolidBackground() throws {
        var s = settings
        s.background = .solid(RGBAColor(r: 0.5, g: 0.3, b: 0.6, a: 0.3))
        s.shadow.opacity = 0 // isolate the background-alpha path
        let out = Compositor().render(RenderInputs(screen: syntheticScreen()),
                                      settings: s, canvasSize: CGSize(width: 400, height: 260))
        XCTAssertTrue(alphaBytes(out).allSatisfy { $0 == 255 },
                      "All output pixels must be fully opaque (alpha 255) even with a < 1 solid background")
    }

    /// Output must always be opaque even when the caller-supplied backgroundImage (e.g. a
    /// wallpaper PNG with transparent corners) carries its own per-pixel alpha < 1.
    func testOutputIsOpaqueWithSemiTransparentImageBackground() throws {
        var s = settings
        s.background = .image(path: "ignored-caller-resolves")
        s.shadow.opacity = 0
        let bg = CIImage(color: CIColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let out = Compositor().render(
            RenderInputs(screen: syntheticScreen(), backgroundImage: bg),
            settings: s, canvasSize: CGSize(width: 400, height: 260))
        XCTAssertTrue(alphaBytes(out).allSatisfy { $0 == 255 },
                      "All output pixels must be fully opaque (alpha 255) even with a semi-transparent backgroundImage")
    }
}
