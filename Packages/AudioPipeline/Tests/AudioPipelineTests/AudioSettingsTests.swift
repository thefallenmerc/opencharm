import XCTest
@testable import AudioPipeline

final class AudioSettingsTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let s = AudioSettings.default
        XCTAssertTrue(s.noiseRemoval)
        XCTAssertTrue(s.voiceEnhance)
        XCTAssertEqual(s.micVolume, 1.0)
        XCTAssertEqual(s.systemVolume, 1.0)
        XCTAssertNil(s.music)
        let back = try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(s, back)
    }

    func testAudioSettingsDecodeWithoutMusic() throws {
        // Additive: settings persisted before `music` existed decode to nil.
        struct LegacyAudioSettings: Codable {
            var noiseRemoval: Bool
            var voiceEnhance: Bool
            var micVolume: Double
            var systemVolume: Double
        }
        let legacy = LegacyAudioSettings(
            noiseRemoval: false, voiceEnhance: true, micVolume: 1.5, systemVolume: 0.5)
        let decoded = try JSONDecoder().decode(
            AudioSettings.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.music)
        XCTAssertFalse(decoded.noiseRemoval)
        XCTAssertEqual(decoded.micVolume, 1.5)
    }

    func testMusicSettingsDefaultsAndRoundTrip() throws {
        let m = MusicSettings(source: "preset:calm")
        XCTAssertEqual(m.volume, 0.4)
        XCTAssertTrue(m.loop)
        let back = try JSONDecoder().decode(MusicSettings.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(m, back)

        var s = AudioSettings.default
        s.music = MusicSettings(source: "music.m4a", volume: 0.75, loop: false)
        let backSettings = try JSONDecoder().decode(
            AudioSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(s, backSettings)
        XCTAssertEqual(backSettings.music?.source, "music.m4a")
        XCTAssertEqual(backSettings.music?.volume, 0.75)
        XCTAssertFalse(backSettings.music?.loop ?? true)
    }
}
