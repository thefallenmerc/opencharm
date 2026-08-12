import CoreImage
import XCTest
@testable import RenderCore

final class AutoZoomTests: XCTestCase {
    private let on = AutoZoomSettings(enabled: true, level: 2.0, speed: 0.5)

    func testDefaultIsEnabled() {
        XCTAssertTrue(AutoZoomSettings.default.enabled)   // zoom-on-click is on by default
    }

    func testDisabledOrEmptyYieldsNoSegments() {
        XCTAssertTrue(AutoZoom.segments(clicks: [ClickEvent(time: 1, point: .init(x: 0.5, y: 0.5))],
                                        settings: AutoZoomSettings(enabled: false)).isEmpty)
        XCTAssertTrue(AutoZoom.segments(clicks: [], settings: on).isEmpty)
    }

    func testNearbyClicksStayOneStaticFocus() {
        let clicks = [
            ClickEvent(time: 3.0, point: .init(x: 0.30, y: 0.40)),
            ClickEvent(time: 3.3, point: .init(x: 0.34, y: 0.44)),
            ClickEvent(time: 3.6, point: .init(x: 0.32, y: 0.42)),
        ]
        let segs = AutoZoom.segments(clicks: clicks, settings: on)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].focusKeys.count, 1)               // all fit one viewport → no pan
        XCTAssertEqual(segs[0].focus.x, 0.30, accuracy: 0.001)   // focus = first click (clamped)
        XCTAssertEqual(segs[0].focus.y, 0.40, accuracy: 0.001)
        XCTAssertEqual(segs[0].scale, 2.0, accuracy: 0.0001)
        // Anticipation: the zoom starts BEFORE the first click and is fully in exactly at it.
        XCTAssertLessThan(segs[0].start, 3.0)
        XCTAssertEqual(segs[0].start + segs[0].easeIn, 3.0, accuracy: 0.001)
        XCTAssertGreaterThan(segs[0].end, 3.6 + 0.5)             // lingers past the last click
    }

    func testOutOfViewClickStartsALowPassPanThatSettles() {
        let clicks = [
            ClickEvent(time: 2.0, point: .init(x: 0.2, y: 0.5)),
            ClickEvent(time: 5.0, point: .init(x: 0.8, y: 0.5)), // within chain, but out of viewport
        ]
        let segs = AutoZoom.segments(clicks: clicks, settings: on)
        XCTAssertEqual(segs.count, 1)                            // one held zoom
        XCTAssertEqual(segs[0].focusKeys.count, 2)               // panned to the second click
        // Holds on the first click until the second lands, then glides (low-pass) and settles.
        // (Focus is no longer viewport-clamped: whole-canvas zoom stays gap-free at the edges.)
        XCTAssertEqual(ZoomTimeline.state(at: 2.5, segments: segs).focus.x, 0.2, accuracy: 0.02)
        XCTAssertEqual(ZoomTimeline.state(at: 5.0, segments: segs).focus.x, 0.2, accuracy: 0.02)
        let mid = ZoomTimeline.state(at: 5.3, segments: segs).focus.x
        XCTAssertGreaterThan(mid, 0.22); XCTAssertLessThan(mid, 0.8)
        XCTAssertEqual(ZoomTimeline.state(at: 6.5, segments: segs).focus.x, 0.8, accuracy: 0.02)
        // Crucially the scale never drops during the pan — it stays zoomed, doesn't zoom out/in.
        XCTAssertEqual(ZoomTimeline.state(at: 5.3, segments: segs).scale, 2.0, accuracy: 0.01)
    }

    // MARK: spring envelope + low-pass pan internals

    func testSpringStepEndpointsAndMonotonicity() {
        XCTAssertEqual(ZoomTimeline.springStep(0, settle: 0.8), 0)
        XCTAssertEqual(ZoomTimeline.springStep(-1, settle: 0.8), 0)
        XCTAssertGreaterThan(ZoomTimeline.springStep(0.8, settle: 0.8), 0.985) // settled at d
        var prev = -1.0
        for i in 0...100 {
            let v = ZoomTimeline.springStep(Double(i) * 0.02, settle: 0.8)
            XCTAssertGreaterThanOrEqual(v, prev)   // monotone
            XCTAssertLessThanOrEqual(v, 1.0)       // never overshoots
            prev = v
        }
    }

    func testSpringStepStartsGently() {
        // Zero velocity at t=0: the first 5% of the settle time moves < 8% of the range
        // (a linear ramp would already be at 5%, accelerating curves much more).
        XCTAssertLessThan(ZoomTimeline.springStep(0.04, settle: 0.8), 0.08)
    }

    func testEnvelopeIsContinuousAt60fps() {
        let s = ZoomSegment(start: 1, end: 6, easeIn: 0.8, easeOut: 0.8,
                            focus: CGPoint(x: 0.5, y: 0.5), scale: 2)
        XCTAssertEqual(ZoomTimeline.envelope(0.9, s), 0)          // before
        XCTAssertGreaterThan(ZoomTimeline.envelope(3.5, s), 0.99) // held ≈ 1
        var prev = 0.0
        for i in 0...299 { // stop shy of end: the envelope legitimately drops to 0 AT t=end
            let v = ZoomTimeline.envelope(1 + Double(i) / 60.0, s)
            XCTAssertLessThan(abs(v - prev), 0.08, "jump at frame \(i)")
            prev = v
        }
    }

    func testPanFilterConvergesWithoutOvershoot() {
        let keys = [FocusKey(time: 1, point: CGPoint(x: 0.3, y: 0.3)),
                    FocusKey(time: 2, point: CGPoint(x: 0.7, y: 0.6))]
        // Pinned to the first key before (and at) its time — no pan during the zoom-in ease.
        XCTAssertEqual(ZoomTimeline.focus(at: 0.5, keys: keys), CGPoint(x: 0.3, y: 0.3))
        let mid = ZoomTimeline.focus(at: 2.2, keys: keys)
        XCTAssertGreaterThan(mid.x, 0.3); XCTAssertLessThan(mid.x, 0.7)      // gliding, no jump
        let settled = ZoomTimeline.focus(at: 5.0, keys: keys)
        XCTAssertEqual(settled.x, 0.7, accuracy: 0.01)                       // converges
        XCTAssertEqual(settled.y, 0.6, accuracy: 0.01)
        for i in 0...100 { // never overshoots the target on either axis
            let p = ZoomTimeline.focus(at: 1 + Double(i) * 0.05, keys: keys)
            XCTAssertLessThanOrEqual(p.x, 0.7 + 1e-9)
            XCTAssertLessThanOrEqual(p.y, 0.6 + 1e-9)
        }
    }

    func testZoomIsFullyInAtTheClickAndHoldsAfter() {
        let segs = AutoZoom.segments(clicks: [ClickEvent(time: 5.0, point: .init(x: 0.4, y: 0.4))],
                                     settings: on)
        // At the click moment the zoom is at full level; it stays there through the post-click hold.
        XCTAssertEqual(ZoomTimeline.state(at: 5.0, segments: segs).scale, 2.0, accuracy: 0.01)
        XCTAssertEqual(ZoomTimeline.state(at: 5.3, segments: segs).scale, 2.0, accuracy: 0.01)
        // A second before the click it is still ramping in (not yet full, but zooming).
        let before = ZoomTimeline.state(at: 4.5, segments: segs).scale
        XCTAssertGreaterThan(before, 1.0)
        XCTAssertLessThan(before, 2.0)
    }

    func testTimeSeparatedClicksSplitAndDoNotOverlap() {
        let clicks = [
            ClickEvent(time: 1.0, point: .init(x: 0.15, y: 0.15)),
            ClickEvent(time: 6.0, point: .init(x: 0.85, y: 0.85)),    // beyond the chain gap → new zoom
        ]
        let segs = AutoZoom.segments(clicks: clicks, settings: on)
        XCTAssertEqual(segs.count, 2)
        XCTAssertLessThan(segs[0].focus.x, 0.3)
        XCTAssertGreaterThan(segs[1].focus.x, 0.7)
        XCTAssertLessThanOrEqual(segs[0].end, segs[1].start + 1e-9)   // non-overlapping
    }

    func testTemporallyCloseClicksChainRegardlessOfLocation() {
        // The core anti-flicker rule: clicks within the chain gap stay ONE zoom even if they're on
        // opposite corners — don't zoom out and back in between them.
        let clicks = [
            ClickEvent(time: 1.0, point: .init(x: 0.1, y: 0.1)),
            ClickEvent(time: 1.2, point: .init(x: 0.9, y: 0.9)),
            ClickEvent(time: 2.9, point: .init(x: 0.5, y: 0.2)), // still within 2s of the previous
        ]
        let segs = AutoZoom.segments(clicks: clicks, settings: on)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].focusKeys.count, 3)    // panned to each out-of-view click, still one zoom
        XCTAssertGreaterThan(segs[0].end, 2.9 + 1.0)  // holds ~1s past the last click, then eases out
    }

    func testSpeedAffectsEaseDurations() {
        let slow = AutoZoom.segments(clicks: [ClickEvent(time: 5, point: .init(x: 0.5, y: 0.5))],
                                     settings: AutoZoomSettings(enabled: true, level: 2, speed: 0.0))
        let fast = AutoZoom.segments(clicks: [ClickEvent(time: 5, point: .init(x: 0.5, y: 0.5))],
                                     settings: AutoZoomSettings(enabled: true, level: 2, speed: 1.0))
        XCTAssertGreaterThan(slow[0].easeIn, fast[0].easeIn)   // slower = longer anticipation
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

    func testProgressIsZeroOutsideAndFullAtClick() {
        // progress drives the webcam shrink: 0 = no zoom (full-size bubble), 1 = fully zoomed.
        let segs = AutoZoom.segments(clicks: [ClickEvent(time: 5, point: .init(x: 0.4, y: 0.4))],
                                     settings: on)
        XCTAssertEqual(ZoomTimeline.state(at: 0.0, segments: segs).progress, 0.0, accuracy: 0.0001)
        XCTAssertEqual(ZoomTimeline.state(at: 5.0, segments: segs).progress, 1.0, accuracy: 0.02)
    }

    // Whole-canvas zoom geometry is covered by CanvasZoomTests.
}
