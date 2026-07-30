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

    public func append(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            if input == nil { start(with: sampleBuffer) }
            guard writer.status == .writing, let input, input.isReadyForMoreMediaData else { return }
            input.append(sampleBuffer)
        }
    }

    private func start(with sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let newInput: AVAssetWriterInput
        switch kind {
        case .hevcVideo(let size, let fps):
            let bitsPerPixelPerFrame = 0.08
            let bitrate = Int(size.width * size.height * CGFloat(fps) * bitsPerPixelPerFrame)
            newInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
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
                input?.markAsFinished()
                writer.finishWriting {
                    if let error = self.writer.error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
        }
    }
}
