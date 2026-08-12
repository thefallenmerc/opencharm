import XCTest
@testable import RenderCore

final class CanvasLayoutTests: XCTestCase {
    var settings: RenderSettings {
        var s = RenderSettings.default
        s.paddingFraction = 0.05          // 40 px on an 800-min-dim canvas
        s.cornerRadiusFraction = 0.02
        s.shadow = ShadowSettings(opacity: 0.5, radius: 0.03, offsetY: 0.012)
        s.webcam = WebcamSettings(visible: true, center: CGPoint(x: 0.85, y: 0.2),
                                  size: 0.25, roundness: 1.0)
        return s
    }

    func testContentRectFitsAspectInsidePadding() {
        let l = CanvasLayout.compute(canvasSize: CGSize(width: 1000, height: 800),
                                     screenAspect: 2.0, settings: settings)
        // padding = 0.05 * 800 = 40 → available 920×720; aspect 2.0 is width-limited: 920×460
        XCTAssertEqual(l.contentRect, CGRect(x: 40, y: 170, width: 920, height: 460))
        // radius = 0.02 * min(920, 460) = 9.2
        XCTAssertEqual(l.cornerRadius, 9.2, accuracy: 0.001)
    }

    func testWebcamRectIsSquareCenteredAndFlipped() {
        let l = CanvasLayout.compute(canvasSize: CGSize(width: 1000, height: 800),
                                     screenAspect: 2.0, settings: settings)
        // side = 0.25 * 800 = 200. center x = 850. y from TOP 0.2 → CI y = (1-0.2)*800 = 640.
        XCTAssertEqual(l.webcamRect, CGRect(x: 750, y: 540, width: 200, height: 200))
        XCTAssertEqual(l.webcamCornerRadius, 100, accuracy: 0.001) // roundness 1 → circle
    }

    func testWebcamRectClampedInsideCanvasWithMargin() {
        var s = settings
        s.webcam.center = CGPoint(x: 0.99, y: 0.01)
        let l = CanvasLayout.compute(canvasSize: CGSize(width: 1000, height: 800),
                                     screenAspect: 2.0, settings: s)
        // Sticky to the corner, but with a 2.5%-of-minDim breathing margin (0.025 * 800 = 20)
        // so the bubble never sits flush against the border.
        XCTAssertEqual(l.webcamRect.maxX, 980, accuracy: 0.001)
        XCTAssertEqual(l.webcamRect.maxY, 780, accuracy: 0.001)
    }

    func testShadowScalesWithCanvas() {
        let l = CanvasLayout.compute(canvasSize: CGSize(width: 1000, height: 800),
                                     screenAspect: 2.0, settings: settings)
        XCTAssertEqual(l.shadowBlurSigma, 0.03 * 800, accuracy: 0.001)
        XCTAssertEqual(l.shadowOffsetY, 0.012 * 800, accuracy: 0.001)
    }
}
