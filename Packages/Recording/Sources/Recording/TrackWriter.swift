import AVFoundation
import CoreMedia

public final class TrackWriter {
    public enum Kind {
        case hevcVideo(size: CGSize, fps: Int)
        case passthroughAudio
    }

    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private let kind: Kind
    private let queue = DispatchQueue(label: "trackwriter")
    private var isFinishing = false
    public private(set) var firstPTSSeconds: Double?

    public init(url: URL, kind: Kind) throws {
        self.kind = kind
        try? FileManager.default.removeItem(at: url)
        switch kind {
        case .hevcVideo:
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        case .passthroughAudio:
            writer = try AVAssetWriter(outputURL: url, fileType: .caf)
        }
    }

    /// Real-time writer: buffers arriving while the input is not ready — e.g. a
    /// ScreenCaptureKit catch-up burst delivered after a display stall, or any buffer
    /// appended after `finish()` has begun tearing the input down — are dropped by
    /// design rather than queued or blocked on. Callers must feed buffers at capture
    /// cadence and must not treat `append` as lossless.
    public func append(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            if input == nil { start(with: sampleBuffer) }
            guard !isFinishing, writer.status == .writing, let input, input.isReadyForMoreMediaData else { return }
            input.append(sampleBuffer)
        }
    }

    private func start(with sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let newInput: AVAssetWriterInput
        switch kind {
        case .hevcVideo(let size, let fps):
            // Encode at the *actual* dimensions of the first delivered frame, not the size the
            // caller guessed up front. AVAssetWriterInput scales every appended frame to
            // AVVideoWidth/HeightKey, so if a source (e.g. the webcam, whose configured size was
            // derived from `activeFormat`) delivers a different aspect ratio, a fixed configured
            // size anamorphically squeezes the whole recording. The screen path is unaffected:
            // its buffers already match the configured capture size.
            let frameDims = CMSampleBufferGetFormatDescription(sampleBuffer)
                .map(CMVideoFormatDescriptionGetDimensions)
            let width = frameDims.map { Int($0.width) } ?? Int(size.width)
            let height = frameDims.map { Int($0.height) } ?? Int(size.height)
            let bitsPerPixelPerFrame = 0.08
            let bitrate = Int(Double(width * height) * Double(fps) * bitsPerPixelPerFrame)
            newInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: fps,
                ],
            ])
        case .passthroughAudio:
            newInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                          sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer))
        }
        newInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(newInput) else { return }
        writer.add(newInput)
        input = newInput
        writer.startWriting()
        writer.startSession(atSourceTime: pts)
        firstPTSSeconds = pts.seconds
    }

    public func finish() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                guard writer.status == .writing else {
                    cont.resume(); return
                }
                isFinishing = true
                input?.markAsFinished()
                writer.finishWriting {
                    if let error = self.writer.error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
        }
    }
}
