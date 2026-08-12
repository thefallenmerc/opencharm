import CoreImage
import XCTest
@testable import RenderCore

final class BlurContentZoomTests: XCTestCase {
    /// Background with a razor-sharp vertical white/black boundary at canvas mid-x.
    private func splitBackground(_ size: CGSize) -> CIImage {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: size))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        return white.composited(over: black)
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let cg = GoldenAssert.cgImage(image)
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &data, width: cg.width, height: cg.height,
                            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let i = (y * cg.width + x) * 4
        return (data[i], data[i + 1], data[i + 2])
    }

    func testBackgroundBlurSoftensTheBoundary() {
        let canvas = CGSize(width: 400, height: 260)
        var s = RenderSettings.default
        s.background = .image(path: "ignored-caller-resolves")
        s.webcam.visible = false
        s.shadow.opacity = 0
        let inputs = RenderInputs(screen: CIImage(color: .gray)
                                      .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200)),
                                  backgroundImage: splitBackground(canvas))

        // Just right of the boundary, at the canvas bottom edge (outside the content rect).
        let sharp = pixel(Compositor().render(inputs, settings: s, canvasSize: canvas),
                          x: 205, y: 256)
        s.backgroundBlur = 1.0
        let soft = pixel(Compositor().render(inputs, settings: s, canvasSize: canvas),
                         x: 205, y: 256)
        XCTAssertLessThan(sharp.r, 40, "unblurred boundary should still be near-black here")
        XCTAssertGreaterThan(Int(soft.r), Int(sharp.r) + 40,
                             "blur should bleed white across the boundary")
    }

    func testContentZoomTightensTheWebcamCrop() {
        // Webcam frame: green with a red stripe on its far-left edge. A 2x content zoom crops to
        // the center half (x 50–150 of 200), which excludes the stripe — so the bubble's left
        // edge flips from red to green.
        let canvas = CGSize(width: 400, height: 260)
        var s = RenderSettings.default
        s.shadow.opacity = 0
        s.webcam = WebcamSettings(visible: true, center: CGPoint(x: 0.5, y: 0.5),
                                  size: 0.5, roundness: 0)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 200))
        let webcam = red.composited(over: green)
        let inputs = RenderInputs(screen: CIImage(color: .gray)
                                      .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200)),
                                  webcam: webcam)

        // Bubble spans x 135–265; sample near its left edge, at the bubble's vertical center.
        let plain = pixel(Compositor().render(inputs, settings: s, canvasSize: canvas),
                          x: 140, y: 130)
        s.webcam.contentZoom = 2.0
        let zoomed = pixel(Compositor().render(inputs, settings: s, canvasSize: canvas),
                           x: 140, y: 130)
        XCTAssertGreaterThan(plain.r, 200, "uncropped bubble edge shows the red half")
        XCTAssertGreaterThan(zoomed.g, 200, "2x content zoom crops into the green center")
    }

    func testNewFieldsAreAdditive() throws {
        let decoded = try JSONDecoder().decode(
            RenderSettings.self, from: JSONEncoder().encode(RenderSettings.default))
        XCTAssertNil(decoded.backgroundBlur)
        XCTAssertNil(decoded.webcam.contentZoom)
    }
}
