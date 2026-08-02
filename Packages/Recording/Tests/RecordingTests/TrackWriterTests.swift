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

    /// Regression (webcam squeeze): the writer is configured with a *guessed* size at start
    /// (WebcamRecorder derived it from the camera's `activeFormat`), but the frames actually
    /// delivered can have a different aspect ratio. `AVAssetWriterInput` scales every appended
    /// frame to `AVVideoWidth/HeightKey`, so a wrong configured size anamorphically squeezes the
    /// recording — the live preview (which renders raw buffers) looks fine while the file is
    /// distorted. The writer must instead encode at each frame's true dimensions. Configure a
    /// SQUARE writer, feed 3:2 frames, and require a 3:2 track out.
    func testVideoWriterHonorsSourceFrameDimensions() async throws {
        let url = tempURL("mov")
        let writer = try TrackWriter(url: url, kind: .hevcVideo(size: CGSize(width: 64, height: 64), fps: 30))
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        for i in 0..<30 {
            let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(i), timescale: 30))
            writer.append(SampleBufferFactory.videoBuffer(pts: pts, size: CGSize(width: 96, height: 64)))
            try await Task.sleep(nanoseconds: NSEC_PER_SEC / 30)
        }
        try await writer.finish()

        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track!.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 96, height: 64))
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

    /// `finish()` marks the input finished and kicks off `finishWriting` asynchronously;
    /// `writer.status` stays `.writing` until that completion fires. Apple's documented contract
    /// for `markAsFinished()` is "do not append additional samples to the input" after calling
    /// it — so any `append(_:)` a producer fires concurrently with `finish()` (e.g. a capture
    /// delegate callback on its own queue racing a "stop recording" call) must never reach
    /// `input.append`. `isFinishing` enforces that explicitly, inside the same serial-queue
    /// critical section as `markAsFinished()`, rather than relying on `isReadyForMoreMediaData`
    /// happening to already reflect "finished" state.
    ///
    /// The background task loops on `!Task.isCancelled` rather than a fixed count, and is only
    /// cancelled after `finish()` returns, so it is guaranteed to still be actively appending —
    /// not finished early, not not-yet-started — for the writer's entire teardown window,
    /// forcing genuine overlap instead of relying on timing luck. A `DispatchSemaphore` confirms
    /// the racer has actually started before `finish()` is invoked. Repeats 10 times to shake out
    /// scheduling variance; asserts no crash and the resulting file stays valid.
    func testConcurrentAppendDuringFinishDoesNotCrash() async throws {
        for _ in 0..<10 {
            let url = tempURL("caf")
            let writer = try TrackWriter(url: url, kind: .passthroughAudio)
            let start = CMClockGetTime(CMClockGetHostTimeClock())

            // Prime the writer so a session is already open before the race begins.
            for i in 0..<3 {
                let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(i * 4800), timescale: 48_000))
                writer.append(SampleBufferFactory.audioBuffer(pts: pts))
            }

            let started = DispatchSemaphore(value: 0)
            let appendTask = Task.detached {
                started.signal()
                var i = 3
                while !Task.isCancelled {
                    let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(i * 4800), timescale: 48_000))
                    writer.append(SampleBufferFactory.audioBuffer(pts: pts))
                    i += 1
                }
            }
            // Bridge the blocking semaphore wait off the async context so we confirm the racer
            // has actually started (not just been submitted) before racing `finish()` against it.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    started.wait()
                    cont.resume()
                }
            }

            try await writer.finish()
            appendTask.cancel()
            _ = await appendTask.value

            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(file.length, 0)
        }
    }
}
