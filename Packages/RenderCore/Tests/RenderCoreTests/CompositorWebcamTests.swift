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
