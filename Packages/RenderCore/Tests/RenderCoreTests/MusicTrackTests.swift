import AVFoundation
import CoreImage
import XCTest
@testable import RenderCore

/// Background-music insertion: a continuous bed inserted AFTER cut/speed retiming, sized to the
/// FINAL composition duration — never chopped by a cut mid-track, never itself time-scaled by
/// playback speed. See the "Background music" comment block in `ProjectCompositionBuilder`.
final class MusicTrackTests: XCTestCase {
    private func musicAudioTrack(in composition: AVComposition) throws -> AVCompositionTrack {
        let tracks = composition.tracks(withMediaType: .audio)
        return try XCTUnwrap(tracks.first)
    }

    func testLoopingMusicFillsTheFinalCompositionDuration() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1),
                                                     seconds: 4)
        let musicURL = try AudioFixture.make(seconds: 1)

        let built = try await ProjectCompositionBuilder.build(
            timeline: MediaTimeline(
                screen: .init(url: screenURL, startOffset: 0), webcam: nil,
                audio: [.init(url: musicURL, startOffset: 0, volume: 0.4,
                              isMusic: true, loops: true)]),
            settings: .default, canvasSize: CGSize(width: 64, height: 48), backgroundImage: nil)

        let musicTrack = try musicAudioTrack(in: built.composition)
        XCTAssertEqual(musicTrack.timeRange.duration.seconds,
                       built.composition.duration.seconds, accuracy: 0.05)
        // A 1 s source looped to fill ~4 s needs several repeated passes.
        XCTAssertGreaterThan(musicTrack.segments.count, 1)
    }

    func testNonLoopingShorterMusicEndsEarly() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1),
                                                     seconds: 3)
        let musicURL = try AudioFixture.make(seconds: 1)

        let built = try await ProjectCompositionBuilder.build(
            timeline: MediaTimeline(
                screen: .init(url: screenURL, startOffset: 0), webcam: nil,
                audio: [.init(url: musicURL, startOffset: 0, volume: 0.4,
                              isMusic: true, loops: false)]),
            settings: .default, canvasSize: CGSize(width: 64, height: 48), backgroundImage: nil)

        let musicTrack = try musicAudioTrack(in: built.composition)
        XCTAssertEqual(musicTrack.timeRange.duration.seconds, 1, accuracy: 0.05)
        XCTAssertLessThan(musicTrack.timeRange.duration.seconds,
                          built.composition.duration.seconds - 0.5,
                          "music should end well before the 3 s composition")
        XCTAssertEqual(musicTrack.segments.count, 1)
    }

    /// Export retime contract: with cuts + 2x speed (`retimeForExport: true`), the music track's
    /// total duration equals the RETIMED composition duration, and every inserted segment maps
    /// its source range 1:1 onto the target (i.e. the music itself is never time-scaled — only
    /// how many loop passes fit changes).
    func testExportRetimeContractCutsAndSpeedDoNotTimeScaleMusic() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1),
                                                     seconds: 4)
        let musicURL = try AudioFixture.make(seconds: 0.5)

        var settings = RenderSettings.default
        settings.cuts = [CutRange(start: 1, end: 2)]  // 4 s → 3 s after the cut
        settings.playbackSpeed = 2.0                   // 3 s → 1.5 s after 2x speed

        let built = try await ProjectCompositionBuilder.build(
            timeline: MediaTimeline(
                screen: .init(url: screenURL, startOffset: 0), webcam: nil,
                audio: [.init(url: musicURL, startOffset: 0, volume: 0.4,
                              isMusic: true, loops: true)]),
            settings: settings, canvasSize: CGSize(width: 64, height: 48), backgroundImage: nil,
            retimeForExport: true)

        XCTAssertEqual(built.composition.duration.seconds, 1.5, accuracy: 0.05)
        let musicTrack = try musicAudioTrack(in: built.composition)
        XCTAssertEqual(musicTrack.timeRange.duration.seconds,
                       built.composition.duration.seconds, accuracy: 0.05)

        // Not time-scaled: every segment's source duration equals its target duration (a plain
        // 1:1 insert), unlike the video track, which WAS scaled by `scaleTimeRange` above.
        for segment in musicTrack.segments {
            XCTAssertEqual(segment.timeMapping.source.duration.seconds,
                           segment.timeMapping.target.duration.seconds, accuracy: 0.01)
            XCTAssertEqual(segment.timeMapping.source.duration.seconds, 0.5, accuracy: 0.01)
        }
    }

    func testFadeRampsAtStartAndEnd() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1),
                                                     seconds: 5)
        let musicURL = try AudioFixture.make(seconds: 6) // longer than the composition

        let built = try await ProjectCompositionBuilder.build(
            timeline: MediaTimeline(
                screen: .init(url: screenURL, startOffset: 0), webcam: nil,
                audio: [.init(url: musicURL, startOffset: 0, volume: 0.6,
                              isMusic: true, loops: false)]),
            settings: .default, canvasSize: CGSize(width: 64, height: 48), backgroundImage: nil)

        let mix = try XCTUnwrap(built.audioMix)
        let params = try XCTUnwrap(mix.inputParameters.first)

        var startVolume: Float = -1, endVolume: Float = -1
        var timeRange = CMTimeRange.zero
        XCTAssertTrue(params.getVolumeRamp(for: .zero, startVolume: &startVolume,
                                           endVolume: &endVolume, timeRange: &timeRange))
        XCTAssertEqual(startVolume, 0, accuracy: 0.01)
        XCTAssertEqual(endVolume, 0.6, accuracy: 0.01)
        XCTAssertEqual(timeRange.start.seconds, 0, accuracy: 0.05)
        XCTAssertEqual(timeRange.duration.seconds, 0.5, accuracy: 0.05) // fade-in base length

        let nearEnd = CMTime(seconds: built.composition.duration.seconds - 0.1,
                             preferredTimescale: 600)
        XCTAssertTrue(params.getVolumeRamp(for: nearEnd, startVolume: &startVolume,
                                           endVolume: &endVolume, timeRange: &timeRange))
        XCTAssertEqual(startVolume, 0.6, accuracy: 0.01)
        XCTAssertEqual(endVolume, 0, accuracy: 0.01)
        XCTAssertEqual(timeRange.duration.seconds, 1.5, accuracy: 0.05) // fade-out base length
    }

    /// The builder never catches the load error for a music track's URL — it propagates exactly
    /// like an unreadable narration/system-audio URL does (`AVURLAsset.loadTracks` throws
    /// `AVFoundationErrorDomain` for a missing file rather than returning empty tracks).
    func testMissingMusicFilePropagatesTheLoadError() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1),
                                                     seconds: 2)
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).mp3")

        do {
            _ = try await ProjectCompositionBuilder.build(
                timeline: MediaTimeline(
                    screen: .init(url: screenURL, startOffset: 0), webcam: nil,
                    audio: [.init(url: missingURL, startOffset: 0, volume: 0.4,
                                  isMusic: true, loops: true)]),
                settings: .default, canvasSize: CGSize(width: 64, height: 48),
                backgroundImage: nil)
            XCTFail("expected build to throw for an unreadable music file")
        } catch {
            // Expected: propagated AVFoundation load error, same as narration/system audio.
        }
    }
}
