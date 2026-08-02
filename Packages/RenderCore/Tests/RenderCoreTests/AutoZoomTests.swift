import CoreImage
import XCTest
@testable import RenderCore

final class AutoZoomTests: XCTestCase {
    private let on = AutoZoomSettings(enabled: true, level: 2.0, speed: 0.5)

    func testDisabledOrEmptyYieldsNoSegments() {
        XCTAssertTrue(AutoZoom.segments(clicks: [ClickEvent(time: 1, point: .init(x: 0.5, y: 0.5))],
                                        settings: AutoZoomSettings(enabled: false)).isEmpty)
        XCTAssertTrue(AutoZoom.segments(clicks: [], settings: on).isEmpty)
    }

    func testNearbyClicksClusterIntoOneSegmentAtCentroid() {
        let clicks = [
            ClickEvent(time: 1.0, point: .init(x: 0.30, y: 0.40)),
            ClickEvent(time: 1.3, point: .init(x: 0.34, y: 0.44)),
            ClickEvent(time: 1.6, point: .init(x: 0.32, y: 0.42)),
        ]
        let segs = AutoZoom.segments(clicks: clicks, settings: on)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].focus.x, 0.32, accuracy: 0.001)
        XCTAssertEqual(segs[0].focus.y, 0.42, accuracy: 0.001)
        XCTAssertEqual(segs[0].scale, 2.0, accuracy: 0.0001)
        XCTAssertEqual(segs[0].start, 1.0, accuracy: 0.0001)          // first click
        XCTAssertGreaterThan(segs[0].end, 1.6)                        // lingers past the last click
    }

    func testFarApartClicksSplitAndDoNotOverlap() {
        let clicks = [
            ClickEvent(time: 1.0, point: .init(x: 0.15, y: 0.15)),    // top-left region
            ClickEvent(time: 3.0, point: .init(x: 0.85, y: 0.85)),    // far away + later
        ]
        let segs = AutoZoom.segments(clicks: clicks, settings: on)
        XCTAssertEqual(segs.count, 2)
        // Distinct focal points.
        XCTAssertLessThan(segs[0].focus.x, 0.3)
        XCTAssertGreaterThan(segs[1].focus.x, 0.7)
        // Non-overlapping and time-ordered.
        XCTAssertLessThanOrEqual(segs[0].end, segs[1].start + 1e-9)
    }

    func testSpatiallyFarButTemporallyCloseClicksSplit() {
        let clicks = [
            ClickEvent(time: 1.0, point: .init(x: 0.1, y: 0.1)),
            ClickEvent(time: 1.2, point: .init(x: 0.9, y: 0.9)), // close in time, far in space
        ]
        XCTAssertEqual(AutoZoom.segments(clicks: clicks, settings: on).count, 2)
    }

    func testSpeedAffectsEaseDurations() {
        let slow = AutoZoom.segments(clicks: [ClickEvent(time: 1, point: .init(x: 0.5, y: 0.5))],
                                     settings: AutoZoomSettings(enabled: true, level: 2, speed: 0.0))
        let fast = AutoZoom.segments(clicks: [ClickEvent(time: 1, point: .init(x: 0.5, y: 0.5))],
                                     settings: AutoZoomSettings(enabled: true, level: 2, speed: 1.0))
        XCTAssertGreaterThan(slow[0].easeIn, fast[0].easeIn)
        XCTAssertGreaterThan(slow[0].easeOut, fast[0].easeOut)
    }

    func testLevelIsClampedTo1p5Through3() {
        let hi = AutoZoom.segments(clicks: [ClickEvent(time: 1, point: .init(x: 0.5, y: 0.5))],
                                   settings: AutoZoomSettings(enabled: true, level: 9, speed: 0.5))
        XCTAssertEqual(hi[0].scale, 3.0, accuracy: 0.0001)
    }

    // MARK: ZoomTimeline evaluation

    func testStateIsIdentityOutsideSegments() {
        let seg = ZoomSegment(start: 2, end: 4, easeIn: 0.4, easeOut: 0.4,
                              focus: .init(x: 0.3, y: 0.3), scale: 2)
        XCTAssertEqual(ZoomTimeline.state(at: 0, segments: [seg]), .identity)
        XCTAssertEqual(ZoomTimeline.state(at: 5, segments: [seg]), .identity)
    }

    func testStateEasesInHoldsAndEasesOut() {
        let seg = ZoomSegment(start: 2, end: 4, easeIn: 0.5, easeOut: 0.5,
                              focus: .init(x: 0.3, y: 0.3), scale: 2)
        let atStart = ZoomTimeline.state(at: 2.0, segments: [seg])
        XCTAssertEqual(atStart.scale, 1.0, accuracy: 0.02)        // just started easing in
        let hold = ZoomTimeline.state(at: 3.0, segments: [seg])   // mid hold
        XCTAssertEqual(hold.scale, 2.0, accuracy: 0.0001)
        XCTAssertEqual(hold.focus.x, 0.3, accuracy: 0.0001)
        let nearEnd = ZoomTimeline.state(at: 3.99, segments: [seg])
        XCTAssertLessThan(nearEnd.scale, 2.0)                     // easing back out
        XCTAssertGreaterThan(nearEnd.scale, 1.0)
    }

    // MARK: Compositor crop geometry

    func testZoomCropIsNoOpAtScaleOne() {
        let img = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let out = Compositor().zoomedScreen(img, zoom: .identity)
        XCTAssertEqual(out.extent, img.extent)
    }

    func testZoomCropShrinksAndCentersOnFocus() {
        let img = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        // scale 2 → 500×500 crop; focus top-left (0.25, 0.25) → CIImage center (250, 750).
        let out = Compositor().zoomedScreen(
            img, zoom: ZoomState(scale: 2, focus: .init(x: 0.25, y: 0.25)))
        XCTAssertEqual(out.extent.width, 500, accuracy: 0.5)
        XCTAssertEqual(out.extent.height, 500, accuracy: 0.5)
        XCTAssertEqual(out.extent.midX, 250, accuracy: 0.5)
        XCTAssertEqual(out.extent.midY, 750, accuracy: 0.5)   // y flipped from top-left focus
    }

    func testZoomCropClampsInsideFrame() {
        let img = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        // focus at extreme corner would push the crop off-frame; it must clamp fully inside.
        let out = Compositor().zoomedScreen(
            img, zoom: ZoomState(scale: 2, focus: .init(x: 0.0, y: 0.0)))
        XCTAssertGreaterThanOrEqual(out.extent.minX, 0)
        XCTAssertGreaterThanOrEqual(out.extent.minY, 0)
        XCTAssertLessThanOrEqual(out.extent.maxX, 1000)
        XCTAssertLessThanOrEqual(out.extent.maxY, 1000)
    }
}
