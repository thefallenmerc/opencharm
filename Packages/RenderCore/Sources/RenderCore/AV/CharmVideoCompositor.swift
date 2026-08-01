import AVFoundation
import CoreImage

/// Carries everything one frame render needs. Immutable per build.
final class CharmInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    var requiredSourceTrackIDs: [NSValue]? {
        var ids = [NSNumber(value: screenTrackID)]
        if let webcamTrackID { ids.append(NSNumber(value: webcamTrackID)) }
        return ids
    }
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let webcamTrackID: CMPersistentTrackID?
    let settings: RenderSettings
    let backgroundImage: CIImage?

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID,
         webcamTrackID: CMPersistentTrackID?, settings: RenderSettings,
         backgroundImage: CIImage?) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.webcamTrackID = webcamTrackID
        self.settings = settings
        self.backgroundImage = backgroundImage
    }
}

/// Holds the last real screen frame so SCK's sparse frame delivery (it only emits on change)
/// doesn't leave gaps between real samples — but only in the forward direction. Preview
/// scrubbing backwards into a gap must not show a frame from later in the timeline: on a
/// backward seek, the cache invalidates and the caller falls back to a background-only render
/// until the next real frame re-primes it.
struct HeldFrameCache {
    private var lastTime: CMTime?
    private var heldImage: CIImage?

    /// - Parameters:
    ///   - source: the real source frame for this request, if SCK delivered one.
    ///   - time: `request.compositionTime` for this request.
    /// - Returns: the image to render, or `nil` if nothing valid is held (caller should fall
    ///   back to a background-only render).
    mutating func resolve(source: CIImage?, at time: CMTime) -> CIImage? {
        if let source {
            lastTime = time
            heldImage = source
            return source
        }
        if let lastTime, time >= lastTime {
            return heldImage
        }
        // Backward seek past the last known real frame, or nothing has ever been held: invalidate.
        lastTime = nil
        heldImage = nil
        return nil
    }
}

public final class CharmVideoCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let compositor = Compositor()
    private let cacheLock = NSLock()
    private var screenFrameCache = HeldFrameCache() // guarded by cacheLock

    public var sourcePixelBufferAttributes: [String: any Sendable]? =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CharmInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "CharmVideoCompositor", code: 1))
            return
        }
        let canvasSize = request.renderContext.size

        let sourcePixelBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID)
        let sourceImage = sourcePixelBuffer.map { CIImage(cvPixelBuffer: $0) }
        cacheLock.lock()
        let resolved = screenFrameCache.resolve(source: sourceImage, at: request.compositionTime)
        cacheLock.unlock()
        let screenImage = resolved ?? CIImage(color: .black)
            .cropped(to: CGRect(origin: .zero, size: canvasSize))

        var webcamImage: CIImage?
        if let id = instruction.webcamTrackID, let pb = request.sourceFrame(byTrackID: id) {
            webcamImage = CIImage(cvPixelBuffer: pb)
        }

        let rendered = compositor.render(
            RenderInputs(screen: screenImage, webcam: webcamImage,
                         backgroundImage: instruction.backgroundImage),
            settings: instruction.settings, canvasSize: canvasSize)
        context.render(rendered, to: output)
        request.finish(withComposedVideoFrame: output)
    }
}
