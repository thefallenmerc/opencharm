import AVFoundation
import CoreImage

public enum ExportResolution: String, CaseIterable, Sendable { case source, fullHD1080, uhd4K }
public enum ExportCodec: String, CaseIterable, Sendable { case h264, hevc }

public struct ExportRequest: Sendable {
    public var outputURL: URL
    public var codec: ExportCodec
    public var resolution: ExportResolution
    public init(outputURL: URL, codec: ExportCodec, resolution: ExportResolution) {
        (self.outputURL, self.codec, self.resolution) = (outputURL, codec, resolution)
    }
}

public enum ExportError: Error { case failed(underlying: Error?), cancelled }

public final class ProjectExporter {
    private let timeline: MediaTimeline
    private let settings: RenderSettings
    private let sourceCanvasSize: CGSize
    private let backgroundImage: CIImage?
    private let cancelled = NSLock()
    private var isCancelled = false

    public init(timeline: MediaTimeline, settings: RenderSettings,
                sourceCanvasSize: CGSize, backgroundImage: CIImage?) {
        self.timeline = timeline
        self.settings = settings
        self.sourceCanvasSize = sourceCanvasSize
        self.backgroundImage = backgroundImage
    }

    public static func pixelSize(for resolution: ExportResolution,
                                 sourceCanvas: CGSize) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat { v.rounded(.down) - v.rounded(.down).truncatingRemainder(dividingBy: 2) }
        switch resolution {
        case .source:
            return CGSize(width: even(sourceCanvas.width), height: even(sourceCanvas.height))
        case .fullHD1080:
            return CGSize(width: even(sourceCanvas.width / sourceCanvas.height * 1080), height: 1080)
        case .uhd4K:
            return CGSize(width: even(sourceCanvas.width / sourceCanvas.height * 2160), height: 2160)
        }
    }

    public func cancel() {
        cancelled.lock(); isCancelled = true; cancelled.unlock()
    }
    private var wasCancelled: Bool {
        cancelled.lock(); defer { cancelled.unlock() }; return isCancelled
    }

    public func export(_ request: ExportRequest,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let canvasSize = Self.pixelSize(for: request.resolution, sourceCanvas: sourceCanvasSize)
        let built = try await ProjectCompositionBuilder.build(
            timeline: timeline, settings: settings, canvasSize: canvasSize,
            backgroundImage: backgroundImage)
        let duration = built.composition.duration.seconds

        try? FileManager.default.removeItem(at: request.outputURL)
        let reader = try AVAssetReader(asset: built.composition)
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = built.videoComposition
        reader.add(videoOut)

        let audioTracks = built.composition.tracks(withMediaType: .audio)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
            ])
            out.audioMix = built.audioMix
            reader.add(out)
            audioOut = out
        }

        let writer = try AVAssetWriter(outputURL: request.outputURL, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: request.codec == .hevc ? AVVideoCodecType.hevc : .h264,
            AVVideoWidthKey: Int(canvasSize.width),
            AVVideoHeightKey: Int(canvasSize.height),
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading(), writer.startWriting() else {
            throw ExportError.failed(underlying: reader.error ?? writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try await Self.pump(input: videoIn, output: videoOut, label: "video") { pts in
                    progress(min(0.99, pts / max(duration, 0.01)))
                    return self?.wasCancelled ?? true
                }
            }
            if let audioIn, let audioOut {
                group.addTask { [weak self] in
                    try await Self.pump(input: audioIn, output: audioOut, label: "audio") { _ in
                        self?.wasCancelled ?? true
                    }
                }
            }
            try await group.waitForAll()
        }

        if wasCancelled {
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ExportError.cancelled
        }
        await writer.finishWriting()
        if writer.status == .failed || reader.status == .failed {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ExportError.failed(underlying: writer.error ?? reader.error)
        }
        progress(1.0)
    }

    /// Pulls samples from `output` into `input`; `tick(ptsSeconds)` returns true to cancel.
    private static func pump(input: AVAssetWriterInput, output: AVAssetReaderOutput,
                             label: String,
                             tick: @escaping @Sendable (Double) -> Bool) async throws {
        let queue = DispatchQueue(label: "export.pump.\(label)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            input.requestMediaDataWhenReady(on: queue) {
                // `requestMediaDataWhenReady`'s block can in principle re-fire before
                // `markAsFinished` has taken effect; guard so the continuation only ever
                // resumes once (a double-resume is a fatal error).
                if resumed { return }
                while input.isReadyForMoreMediaData {
                    guard let sb = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        if !resumed { resumed = true; cont.resume() }
                        return
                    }
                    if tick(CMSampleBufferGetPresentationTimeStamp(sb).seconds) {
                        input.markAsFinished()
                        if !resumed { resumed = true; cont.resume() }
                        return
                    }
                    input.append(sb)
                }
            }
        }
    }
}
