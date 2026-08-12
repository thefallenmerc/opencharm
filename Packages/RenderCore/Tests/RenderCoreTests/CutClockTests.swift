import XCTest
@testable import RenderCore

final class CutClockTests: XCTestCase {
    func testNormalizeMergesSortsAndClamps() {
        let cuts = CutClock.normalized([
            CutRange(start: 8, end: 20),      // clamped to duration
            CutRange(start: 3, end: 4),
            CutRange(start: 3.5, end: 5),     // overlaps previous → merged
            CutRange(start: -1, end: 0.5),    // clamped to 0
            CutRange(start: 6, end: 6.01),    // sub-minimum → dropped
        ], duration: 10)
        XCTAssertEqual(cuts, [CutRange(start: 0, end: 0.5),
                              CutRange(start: 3, end: 5),
                              CutRange(start: 8, end: 10)])
    }

    func testMapShiftsPastCuts() {
        let cuts = [CutRange(start: 2, end: 3), CutRange(start: 5, end: 7)]
        XCTAssertEqual(CutClock.map(1, cuts: cuts), 1)          // before any cut
        XCTAssertEqual(CutClock.map(2.5, cuts: cuts), 2)        // inside → collapses to cut start
        XCTAssertEqual(CutClock.map(4, cuts: cuts), 3)          // after first cut → -1s
        XCTAssertEqual(CutClock.map(8, cuts: cuts), 5)          // after both → -3s
    }

    func testSegmentRemapDropsAndShrinks() {
        let cuts = [CutRange(start: 4, end: 6)]
        let inside = ZoomSegment(start: 4.2, end: 5.8, easeIn: 0.4, easeOut: 0.4,
                                 focus: .init(x: 0.5, y: 0.5), scale: 2)
        XCTAssertNil(CutClock.remap(inside, cuts: cuts))        // fully deleted → gone
        let straddling = ZoomSegment(start: 3, end: 7, easeIn: 0.5, easeOut: 0.5,
                                     focus: .init(x: 0.5, y: 0.5), scale: 2)
        let out = CutClock.remap(straddling, cuts: cuts)
        XCTAssertEqual(out?.start, 3)
        XCTAssertEqual(out?.end, 5)                             // 4s long minus the 2s cut
        let after = ZoomSegment(start: 7, end: 9, easeIn: 0.5, easeOut: 0.5,
                                focus: .init(x: 0.5, y: 0.5), scale: 2)
        XCTAssertEqual(CutClock.remap(after, cuts: cuts)?.start, 5)
    }
}
