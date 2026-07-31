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
}
