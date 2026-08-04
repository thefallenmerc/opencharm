import CoreImage
import XCTest
@testable import RenderCore

final class CursorTests: XCTestCase {
    private func screen() -> CIImage {
        CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.9))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
    }
    private func cursorImg() -> CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func testTrackLookupHoldsNearestPreceding() {
        let s = [CursorSample(time: 0, point: .init(x: 0.1, y: 0.1)),
                 CursorSample(time: 1, point: .init(x: 0.5, y: 0.5)),
                 CursorSample(time: 2, point: .init(x: 0.9, y: 0.9))]
        XCTAssertNil(CursorTrack.point(at: 0.5, samples: []))
        XCTAssertEqual(CursorTrack.point(at: -1, samples: s), .init(x: 0.1, y: 0.1)) // before first
        XCTAssertEqual(CursorTrack.point(at: 1.4, samples: s), .init(x: 0.5, y: 0.5)) // between → prev
        XCTAssertEqual(CursorTrack.point(at: 9, samples: s), .init(x: 0.9, y: 0.9))   // after last
    }

    func testCursorChangesOutputWhenInView() {
        let c = Compositor()
        let canvas = CGSize(width: 400, height: 260)
        var s = RenderSettings.default
        s.webcam.visible = false
        let without = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas)
        let cf = CursorFrame(image: cursorImg(), point: .init(x: 0.5, y: 0.5), sizeFraction: 0.1)
        let with = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas, cursor: cf)
        XCTAssertGreaterThan(
            GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(with), GoldenAssert.cgImage(without)), 0.0001)
    }

    func testCursorOutsideZoomViewportIsNotDrawn() {
        let c = Compositor()
        let canvas = CGSize(width: 400, height: 260)
        var s = RenderSettings.default
        s.webcam.visible = false
        let zoom = ZoomState(scale: 2, focus: .init(x: 0.2, y: 0.2), progress: 1)
        let base = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas, zoom: zoom)
        // pointer far from the zoomed-in region → mapped outside the crop → not drawn.
        let cf = CursorFrame(image: cursorImg(), point: .init(x: 0.95, y: 0.95), sizeFraction: 0.1)
        let withC = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                             zoom: zoom, cursor: cf)
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(base), GoldenAssert.cgImage(withC)), 0.0001)
    }
}
