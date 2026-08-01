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

public final class CharmVideoCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let compositor = Compositor()
    private var lastScreenFrame: CIImage? // SCK only emits frames on change; hold the last one

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

        var screenImage: CIImage
        if let pb = request.sourceFrame(byTrackID: instruction.screenTrackID) {
            screenImage = CIImage(cvPixelBuffer: pb)
            lastScreenFrame = screenImage
        } else if let held = lastScreenFrame {
            screenImage = held
        } else {
            screenImage = CIImage(color: .black)
                .cropped(to: CGRect(origin: .zero, size: canvasSize))
        }
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
