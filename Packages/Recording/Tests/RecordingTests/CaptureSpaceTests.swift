import XCTest
@testable import Recording

final class CaptureSpaceTests: XCTestCase {
    func testMapsEventsThroughInitialRect() {
        let events = [
            LoggedEvent(t: 1, x: 150, y: 250, type: "down"),
            LoggedEvent(t: 2, x: 100, y: 200, type: "move"),
        ]
        let rect = CGRect(x: 100, y: 200, width: 200, height: 100)
        let mapped = CaptureSpace.normalize(events: events, initial: rect)
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[0].point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(mapped[0].point.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mapped[1].point.x, 0, accuracy: 0.0001)
        XCTAssertEqual(mapped[1].point.y, 0, accuracy: 0.0001)
    }

    func testRectEventRetargetsLaterClicks() {
        // Window starts at (0,0,100,100), then moves to (500,500,100,100) at t=5.
        // The same click coordinates land inside the first rect but outside the second.
        let events = [
            LoggedEvent(t: 1, x: 50, y: 50, type: "down"),
            LoggedEvent(t: 5, x: 500, y: 500, type: "rect", w: 100, h: 100),
            LoggedEvent(t: 6, x: 550, y: 575, type: "down"),
            LoggedEvent(t: 7, x: 50, y: 50, type: "down"), // now outside the moved window
        ]
        let mapped = CaptureSpace.normalize(events: events,
                                            initial: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[0].event.t, 1)
        XCTAssertEqual(mapped[0].point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mapped[1].event.t, 6)
        XCTAssertEqual(mapped[1].point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mapped[1].point.y, 0.75, accuracy: 0.0001)
    }

    func testNoRectAnywhereDropsEverything() {
        let events = [LoggedEvent(t: 1, x: 50, y: 50, type: "down")]
        XCTAssertTrue(CaptureSpace.normalize(events: events, initial: nil).isEmpty)
    }

    func testRectEventAloneEnablesMappingWithoutInitialRect() {
        let events = [
            LoggedEvent(t: 0, x: 10, y: 10, type: "rect", w: 100, h: 100),
            LoggedEvent(t: 1, x: 60, y: 60, type: "down"),
        ]
        let mapped = CaptureSpace.normalize(events: events, initial: nil)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].point.x, 0.5, accuracy: 0.0001)
    }

    func testRectEventsAreNotEmittedAsSamples() {
        let events = [LoggedEvent(t: 0, x: 0, y: 0, type: "rect", w: 100, h: 100)]
        XCTAssertTrue(CaptureSpace.normalize(events: events,
                                             initial: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    }

    func testLoggedEventRectFieldsRoundTripAndOldLinesDecode() throws {
        let rect = LoggedEvent(t: 1, x: 2, y: 3, type: "rect", w: 640, h: 480)
        let data = try JSONEncoder().encode(rect)
        let back = try JSONDecoder().decode(LoggedEvent.self, from: data)
        XCTAssertEqual(back, rect)
        // Lines written before w/h existed must still decode.
        let old = try JSONDecoder().decode(
            LoggedEvent.self,
            from: Data(#"{"t":1,"x":2,"y":3,"type":"down"}"#.utf8))
        XCTAssertNil(old.w)
        XCTAssertNil(old.h)
    }
}
