import XCTest
@testable import RenderCore

final class PlaybackSpeedTests: XCTestCase {
    func testZoomSegmentScaling() {
        let s = ZoomSegment(start: 2, end: 6, easeIn: 0.8, easeOut: 0.5, scale: 2,
                            focusKeys: [FocusKey(time: 2.5, point: .init(x: 0.4, y: 0.4))])
        let half = s.scaled(by: 0.5) // 2x speed → times halve
        XCTAssertEqual(half.start, 1)
        XCTAssertEqual(half.end, 3)
        XCTAssertEqual(half.easeIn, 0.4)
        XCTAssertEqual(half.easeOut, 0.25)
        XCTAssertEqual(half.focusKeys[0].time, 1.25)
        XCTAssertEqual(half.focusKeys[0].point, CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(half.scale, 2) // magnification untouched
    }

    func testSettingsDecodeWithoutSpeed() throws {
        // Additive: settings persisted before the field existed decode to nil.
        let decoded = try JSONDecoder().decode(
            RenderSettings.self, from: JSONEncoder().encode(RenderSettings.default))
        XCTAssertNil(decoded.playbackSpeed)
    }
}
