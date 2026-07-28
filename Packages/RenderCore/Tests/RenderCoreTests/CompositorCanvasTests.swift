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
}
