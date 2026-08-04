import CoreGraphics
import XCTest
@testable import ProjectStore
import RenderCore
import AudioPipeline

final class ManifestTests: XCTestCase {
    func fullManifest() -> ProjectManifest {
        ProjectManifest(
            schemaVersion: ProjectManifest.currentSchemaVersion,
            createdAt: Date(timeIntervalSince1970: 1_754_000_000),
            screen: TrackRef(filename: "screen.mov", startOffset: 0),
            webcam: TrackRef(filename: "webcam.mov", startOffset: 0.041),
            mic: TrackRef(filename: "mic.caf", startOffset: 0.012),
            systemAudio: TrackRef(filename: "system.caf", startOffset: 0),
            renderSettings: .default,
            audioSettings: .default)
    }

    func testRoundTrip() throws {
        let m = fullManifest()
        // Encode via ManifestMigrator.save (not a bare JSONEncoder()): the
        // migrator's encoder pins .secondsSince1970 to match .load's decoder
        // and the frozen v1 fixture. A default JSONEncoder() uses
        // .deferredToDate (seconds since the 2001 reference date), which
        // .load's .secondsSince1970 decoder would misinterpret.
        let back = try ManifestMigrator.load(from: try ManifestMigrator.save(m))
        XCTAssertEqual(m, back)
    }

    func testV1FixtureAlwaysOpens() throws {
        let url = Bundle.module.url(forResource: "Fixtures/manifest-v1", withExtension: "json")!
        let m = try ManifestMigrator.load(from: try Data(contentsOf: url))
        XCTAssertEqual(m.schemaVersion, 1)
        XCTAssertEqual(m.screen.filename, "screen.mov")
        XCTAssertNil(m.webcam)
    }

    func testUnknownVersionRejected() throws {
        let bad = #"{"schemaVersion": 999}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ManifestMigrator.load(from: bad))
    }

    func testCaptureRectRoundTrips() throws {
        var m = fullManifest()
        m.captureRect = CGRect(x: 100, y: 50, width: 1920, height: 1080)
        m.hidesSystemCursor = true
        let back = try ManifestMigrator.load(from: try ManifestMigrator.save(m))
        XCTAssertEqual(back.captureRect, CGRect(x: 100, y: 50, width: 1920, height: 1080))
        XCTAssertEqual(back.hidesSystemCursor, true)
        XCTAssertEqual(m, back)
    }

    // A manifest written before captureRect existed (the v1 fixture) must still decode, with a nil
    // captureRect — the additive optional field is backward compatible.
    func testV1FixtureDecodesWithNilCaptureRect() throws {
        let url = Bundle.module.url(forResource: "Fixtures/manifest-v1", withExtension: "json")!
        let m = try ManifestMigrator.load(from: try Data(contentsOf: url))
        XCTAssertNil(m.captureRect)
    }
}
