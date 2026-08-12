import CoreImage
import XCTest
@testable import RenderCore

/// Whole-canvas zoom: the background/padding magnify with the content, the focus point stays at
/// its on-screen position, and the canvas is always fully covered.
final class CanvasZoomTests: XCTestCase {
    private let canvasRect = CGRect(x: 0, y: 0, width: 400, height: 260)
    private let contentRect = CGRect(x: 20, y: 15, width: 360, height: 230)

    func testIdentityZoomIsNoOp() {
        let img = CIImage(color: .gray).cropped(to: canvasRect)
        let out = Compositor().zoomedCanvas(img, zoom: .identity,
                                            contentRect: contentRect, canvasRect: canvasRect)
        XCTAssertEqual(out.extent, canvasRect)
    }

    func testZoomAlwaysCoversTheCanvas() {
        let img = CIImage(color: .gray).cropped(to: canvasRect)
        // Even an extreme corner focus leaves no gap: scaling up about an interior point only
        // pushes edges outward.
        for focus in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.1, y: 0.9)] {
            let out = Compositor().zoomedCanvas(
                img, zoom: ZoomState(scale: 2, focus: focus, progress: 1),
                contentRect: contentRect, canvasRect: canvasRect)
            XCTAssertEqual(out.extent, canvasRect, "gap for focus \(focus)")
        }
    }

    func testFocusPointStaysPutAndBackgroundZooms() {
        // A marker at the focus point must stay at the same canvas position after zooming
        // (Screen Charm zooms "in place" toward the click).
        let focus = CGPoint(x: 0.25, y: 0.4) // normalized in content space, top-left origin
        let markerCanvasX = contentRect.minX + focus.x * contentRect.width          // 110
        let markerCanvasY = contentRect.maxY - focus.y * contentRect.height         // y-up: 153
        let marker = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(
            to: CGRect(x: markerCanvasX - 2, y: markerCanvasY - 2, width: 4, height: 4))
        let img = marker.composited(over: CIImage(color: .gray).cropped(to: canvasRect))
        let out = Compositor().zoomedCanvas(
            img, zoom: ZoomState(scale: 2, focus: focus, progress: 1),
            contentRect: contentRect, canvasRect: canvasRect)
        let px = pixel(out, x: Int(markerCanvasX), y: Int(260 - markerCanvasY)) // top-left sampling
        XCTAssertGreaterThan(px.r, 200, "focus marker moved off its screen position")
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

    // MARK: cursor follow

    func testZoomFollowsCursorSoftlyAfterSettle() {
        let seg = ZoomSegment(start: 1, end: 10, easeIn: 1, easeOut: 0.6,
                              focus: CGPoint(x: 0.3, y: 0.3), scale: 2)
        let track = [
            CursorSample(time: 0.0, point: CGPoint(x: 0.3, y: 0.3)),
            CursorSample(time: 3.0, point: CGPoint(x: 0.8, y: 0.7)),
        ]
        // While easing in: pinned to the click focus, no drift.
        let easing = ZoomTimeline.state(at: 1.5, segments: [seg], cursorTrack: track)
        XCTAssertEqual(easing.focus.x, 0.3, accuracy: 0.001)
        // Right as the cursor jumps: barely moved yet (low-pass lag).
        let early = ZoomTimeline.state(at: 3.1, segments: [seg], cursorTrack: track)
        XCTAssertLessThan(early.focus.x, 0.45)
        XCTAssertGreaterThan(early.focus.x, 0.3 - 1e-9)
        // Well after: converged on the cursor.
        let settled = ZoomTimeline.state(at: 6.0, segments: [seg], cursorTrack: track)
        XCTAssertEqual(settled.focus.x, 0.8, accuracy: 0.02)
        XCTAssertEqual(settled.focus.y, 0.7, accuracy: 0.02)
        // Empty track keeps the key-based pan.
        let keyed = ZoomTimeline.state(at: 6.0, segments: [seg], cursorTrack: [])
        XCTAssertEqual(keyed.focus.x, 0.3, accuracy: 0.001)
    }

    // MARK: click pulse

    func testCursorPulseShrinksAndRecovers() {
        let clicks = [2.0]
        XCTAssertEqual(CursorPulse.scale(at: 1.9, clicks: clicks), 1)              // before
        let pressed = CursorPulse.scale(at: 2.07, clicks: clicks)                  // mid-press
        XCTAssertLessThan(pressed, 0.9)
        XCTAssertEqual(CursorPulse.scale(at: 2.09, clicks: clicks),
                       CursorPulse.depth, accuracy: 0.01)                          // bottom
        let recovering = CursorPulse.scale(at: 2.2, clicks: clicks)
        XCTAssertGreaterThan(recovering, CursorPulse.depth)
        XCTAssertLessThan(recovering, 1)
        XCTAssertEqual(CursorPulse.scale(at: 3.0, clicks: clicks), 1)              // recovered
        XCTAssertEqual(CursorPulse.scale(at: 5, clicks: []), 1)                    // no clicks
    }
}
