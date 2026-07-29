import XCTest
@testable import AudioPipeline

final class AudioSettingsTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let s = AudioSettings.default
        XCTAssertTrue(s.noiseRemoval)
        XCTAssertTrue(s.voiceEnhance)
        XCTAssertEqual(s.micVolume, 1.0)
        XCTAssertEqual(s.systemVolume, 1.0)
        let back = try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(s, back)
    }
}
