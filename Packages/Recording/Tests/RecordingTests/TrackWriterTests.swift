import AVFoundation
import XCTest
@testable import Recording

final class TrackWriterTests: XCTestCase {
    func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tw-\(UUID().uuidString).\(ext)")
    }

    func testVideoWriterProducesReadableMovie() async throws {
        let url = tempURL("mov")
        let writer = try TrackWriter(url: url, kind: .hevcVideo(size: CGSize(width: 64, height: 64), fps: 30))
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        for i in 0..<30 {
            let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(i), timescale: 30))
            writer.append(SampleBufferFactory.videoBuffer(pts: pts))
            // Real capture sources (Tasks 10-13) deliver frames at real cadence, which is what
            // lets `expectsMediaDataInRealTime` throttle correctly. Appending all 30 frames
            // back-to-back with no delay runs presentation time far ahead of wall-clock time,
            // so AVAssetWriterInput legitimately drops the burst (isReadyForMoreMediaData
            // stays false) regardless of frame size. Pace appends to match real 30 fps capture.
            try await Task.sleep(nanoseconds: NSEC_PER_SEC / 30)
        }
        try await writer.finish()

        XCTAssertEqual(writer.firstPTSSeconds!, start.seconds, accuracy: 0.001)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.15)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    func testAudioPassthroughToCAF() async throws {
        let url = tempURL("caf")
        let writer = try TrackWriter(url: url, kind: .passthroughAudio)
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        for i in 0..<10 { // 10 × 0.1 s
            let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(i * 4800), timescale: 48_000))
            writer.append(SampleBufferFactory.audioBuffer(pts: pts))
        }
        try await writer.finish()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 1.0, accuracy: 0.05)
        XCTAssertEqual(writer.firstPTSSeconds!, start.seconds, accuracy: 0.001)
    }
}
