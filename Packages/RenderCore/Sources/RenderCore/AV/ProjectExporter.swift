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
        // Pre-flight: an already-cancelled exporter shouldn't pay for the (comparatively
        // expensive) composition build at all.
        if wasCancelled { throw ExportError.cancelled }

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

        if wasCancelled {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ExportError.cancelled
        }

        guard reader.startReading(), writer.startWriting() else {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ExportError.failed(underlying: reader.error ?? writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    try await Self.pump(input: videoIn, output: videoOut, writer: writer, label: "video") { pts in
                        progress(min(0.99, pts / max(duration, 0.01)))
                        return self?.wasCancelled ?? true
                    }
                }
                if let audioIn, let audioOut {
                    group.addTask { [weak self] in
                        try await Self.pump(input: audioIn, output: audioOut, writer: writer, label: "audio") { _ in
                            self?.wasCancelled ?? true
                        }
                    }
                }
                // Drain with `next()` rather than `waitForAll()`: a plain `ThrowingTaskGroup`
                // does NOT cancel its remaining children just because one throws — verified
                // empirically (a sibling stuck on an unresumed continuation blocks
                // `waitForAll()` forever even after another child throws). So on the first
                // error we explicitly `cancelAll()`, which flips `Task.isCancelled` for the
                // still-running sibling; `pump`'s `withTaskCancellationHandler` observes that
                // and force-resumes its own continuation, letting this loop finish draining
                // every child (satisfying structured concurrency) instead of hanging.
                var firstError: Error?
                while true {
                    do {
                        guard try await group.next() != nil else { break }
                    } catch {
                        if firstError == nil {
                            firstError = error
                            group.cancelAll()
                        }
                    }
                }
                if let firstError { throw firstError }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: request.outputURL)
            throw error
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

    /// Bridges `pump`'s completion-callback loop into a single-resume `async throws`.
    /// Two independent triggers can resume it — the `requestMediaDataWhenReady` callback
    /// (on the pump's own serial queue) and a task-cancellation handler (on an arbitrary
    /// thread, once a sibling pump fails and `export()` cancels the group) — so both the
    /// "mark the input finished" step and the "resume the continuation" step are guarded
    /// by one lock to stay safe under either interleaving, including cancellation arriving
    /// before the continuation has even been registered.
    private final class PumpContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var pendingResult: Result<Void, Error>?
        private var finishedInput = false

        func register(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if let pendingResult {
                lock.unlock()
                Self.settle(continuation, pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ input: AVAssetWriterInput, _ result: Result<Void, Error>) {
            lock.lock()
            guard pendingResult == nil else { lock.unlock(); return }
            pendingResult = result
            let alreadyFinishedInput = finishedInput
            finishedInput = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            if !alreadyFinishedInput { input.markAsFinished() }
            if let continuation { Self.settle(continuation, result) }
        }

        private static func settle(_ continuation: CheckedContinuation<Void, Error>,
                                   _ result: Result<Void, Error>) {
            switch result {
            case .success: continuation.resume()
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    /// Pulls samples from `output` into `input`; `tick(ptsSeconds)` returns true to cancel.
    /// Throws `ExportError.failed` if the writer rejects a sample (e.g. it has failed or
    /// been cancelled), rather than silently discarding `append`'s Bool result — an
    /// unchecked failed `append` would otherwise leave `isReadyForMoreMediaData` false
    /// forever with no further readiness callback, hanging `export()` unrecoverably.
    static func pump(input: AVAssetWriterInput, output: AVAssetReaderOutput,
                     writer: AVAssetWriter, label: String,
                     tick: @escaping @Sendable (Double) -> Bool) async throws {
        let queue = DispatchQueue(label: "export.pump.\(label)")
        let box = PumpContinuation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.register(cont)
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        guard let sb = output.copyNextSampleBuffer() else {
                            box.finish(input, .success(()))
                            return
                        }
                        if tick(CMSampleBufferGetPresentationTimeStamp(sb).seconds) {
                            box.finish(input, .success(()))
                            return
                        }
                        if !input.append(sb) {
                            box.finish(input, .failure(ExportError.failed(underlying: writer.error)))
                            return
                        }
                    }
                }
            }
        } onCancel: {
            // The real failure (if any) is already carried by whichever sibling pump threw
            // first; this pump just needs to stop cleanly so the group can finish draining.
            box.finish(input, .success(()))
        }
    }
}
