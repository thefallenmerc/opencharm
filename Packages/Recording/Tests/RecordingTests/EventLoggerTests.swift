import XCTest
@testable import Recording

final class EventLoggerTests: XCTestCase {
    func testLogsThrottlesAndFinalizesRelativeToEpoch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ev-\(UUID().uuidString).jsonl")
        let logger = EventLogger(fileURL: url)
        logger.log(LoggedEvent(t: 100.000, x: 10, y: 20, type: "move"))
        logger.log(LoggedEvent(t: 100.004, x: 11, y: 20, type: "move")) // < 1/120 s later: dropped
        logger.log(LoggedEvent(t: 100.020, x: 12, y: 21, type: "move"))
        logger.log(LoggedEvent(t: 100.021, x: 12, y: 21, type: "down")) // clicks never throttled
        try logger.finalize(epoch: 99.5)

        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let first = try JSONDecoder().decode(LoggedEvent.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.t, 0.5, accuracy: 0.0001)
        XCTAssertEqual(first.type, "move")
        let click = try JSONDecoder().decode(LoggedEvent.self, from: Data(lines[2].utf8))
        XCTAssertEqual(click.type, "down")
    }

    func testCoordinateConversionPreservesQuartzGlobalSpace() throws {
        // Coordinates stored via log(_:) are Quartz top-left global (primary-anchored).
        // The conversion screenH - cocoaY is display-agnostic:
        // - Primary display cursor at Cocoa (x: 100, cocoaY: 500) with screenH=1440
        //   → Quartz (100, 1440 − 500) = (100, 940) ✓ within primary bounds
        // - Cursor on secondary display to the left at Cocoa (x: −100, cocoaY: 800)
        //   → Quartz (−100, 1440 − 800) = (−100, 640) ✓ negative x in Quartz (expected left display)
        // - Cursor on secondary display below at Cocoa (x: 500, cocoaY: −200)
        //   → Quartz (500, 1440 − (−200)) = (500, 1640) ✓ y > 1440 in Quartz (expected below primary)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ev-\(UUID().uuidString).jsonl")
        let logger = EventLogger(fileURL: url)

        // Simulate events already in Quartz space (as if from a screenH=1440 primary display):
        // Primary display event
        logger.log(LoggedEvent(t: 100.0, x: 100, y: 940, type: "move"))
        // Secondary display: left (negative x)
        logger.log(LoggedEvent(t: 100.1, x: -100, y: 640, type: "move"))
        // Secondary display: below (y > 1440)
        logger.log(LoggedEvent(t: 100.2, x: 500, y: 1640, type: "move"))

        try logger.finalize(epoch: 99.5)

        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)

        let primary = try JSONDecoder().decode(LoggedEvent.self, from: Data(lines[0].utf8))
        XCTAssertEqual(primary.x, 100)
        XCTAssertEqual(primary.y, 940)
        XCTAssertEqual(primary.t, 0.5, accuracy: 0.0001)

        let left = try JSONDecoder().decode(LoggedEvent.self, from: Data(lines[1].utf8))
        XCTAssertEqual(left.x, -100, "Left display has negative x coordinate")
        XCTAssertEqual(left.y, 640, "Left display y in [0, 1440]")
        XCTAssertEqual(left.t, 0.6, accuracy: 0.0001)

        let below = try JSONDecoder().decode(LoggedEvent.self, from: Data(lines[2].utf8))
        XCTAssertEqual(below.x, 500, "Below display has x within primary bounds")
        XCTAssertEqual(below.y, 1640, "Below display has y > primary height")
        XCTAssertEqual(below.t, 0.7, accuracy: 0.0001)
    }
}
