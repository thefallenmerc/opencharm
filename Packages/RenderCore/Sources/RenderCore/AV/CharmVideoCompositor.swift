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
    let zoomSegments: [ZoomSegment]
    let cursorSamples: [CursorSample]
    let cursorArt: CursorArt?
    let cursorSize: Double
    let clickTimes: [Double]
    /// Full click events (time + point), cut-remapped and speed-scaled identically to
    /// `clickTimes` (same single remap pass in `ProjectCompositionBuilder` — see its comment for
    /// why they're guaranteed to stay in parity). Drives ripple/sonar/sparkle click effects,
    /// which need the click's position as well as its time.
    let clickEvents: [ClickEvent]
    let blurBoxes: [BlurBoxSpec]
    let annotations: [AnnotationSpec]

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID,
         webcamTrackID: CMPersistentTrackID?, settings: RenderSettings,
         backgroundImage: CIImage?, zoomSegments: [ZoomSegment] = [],
         cursorSamples: [CursorSample] = [], cursorArt: CursorArt? = nil,
         cursorSize: Double = 0.04,
         clickTimes: [Double] = [], clickEvents: [ClickEvent] = [],
         blurBoxes: [BlurBoxSpec] = [],
         annotations: [AnnotationSpec] = []) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.webcamTrackID = webcamTrackID
        self.settings = settings
        self.backgroundImage = backgroundImage
        self.zoomSegments = zoomSegments
        self.cursorSamples = cursorSamples
        self.cursorArt = cursorArt
        self.cursorSize = cursorSize
        self.clickTimes = clickTimes
        self.clickEvents = clickEvents
        self.blurBoxes = blurBoxes
        self.annotations = annotations
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

        let t = request.compositionTime.seconds
        let zoom = ZoomTimeline.state(at: t, segments: instruction.zoomSegments,
                                      cursorTrack: instruction.cursorSamples)
        // 3D motion: the content card leans with the pointer's velocity, gated on the zoom
        // envelope so it fades in and out with the magnification and is exactly identity (the
        // compositor's byte-identical flat path) whenever no zoom is engaged. `cursorSamples`
        // are already cut- and speed-remapped by the builder, so the tilt retimes for free.
        let tilt = MotionTilt.state(at: t, samples: instruction.cursorSamples,
                                    zoomProgress: zoom.progress,
                                    settings: instruction.settings.motion3D)
        // Camera velocity for cinematic motion blur: a finite difference of the stateless
        // ZoomTimeline evaluator straddling `t`, never accumulated frame-to-frame state — safe
        // under AVFoundation's out-of-order concurrent request queue. Only evaluated when the
        // feature is actually on, so an off project pays for nothing extra per frame.
        let eps = 1.0 / 120
        let camVel: CameraVelocity
        if (instruction.settings.motionBlur ?? 0) > 0.005 {
            let zPrev = ZoomTimeline.state(at: t - eps, segments: instruction.zoomSegments,
                                           cursorTrack: instruction.cursorSamples)
            let zNext = ZoomTimeline.state(at: t + eps, segments: instruction.zoomSegments,
                                           cursorTrack: instruction.cursorSamples)
            camVel = .between(zPrev, zNext, dt: 2 * eps)
        } else {
            camVel = .zero
        }
        // Click effect: resolved once per frame, then gated on synthetic-cursor presence below —
        // legacy recordings with a baked-in system cursor (`cursorArt == nil`) get no effects at
        // all, ripple/sonar/sparkle/spotlight included.
        let clickEffectKind = ClickEffectKind.resolve(instruction.settings.clickEffect)
        var cursor: CursorFrame?
        var clickRings: [ClickEffects.Ring] = []
        var clickSpokes: [ClickEffects.Spoke] = []
        if let art = instruction.cursorArt,
           let sample = CursorTrack.sample(at: t, samples: instruction.cursorSamples) {
            // Pointer shape follows the recorded cursor type; the click pulse shrinks it
            // briefly on mouse-down (scaling the size fraction keeps the hotspot anchored).
            // A style with no distinct hand art falls back to the arrow — image and hotspot
            // together, so the fallback art still anchors correctly.
            let usesHand = sample.cursorType == "pointingHand" && art.hand != nil
            let image = usesHand ? art.hand! : art.arrow
            let hotspot = usesHand ? art.handHotspot : art.hotspot
            // "none" turns the pulse haptic off; every other kind (incl. nil/"pulse") keeps it —
            // the new ring/spoke/spotlight effects compose with the pulse, they don't replace it.
            let pulse = ClickEffects.pulseEnabled(clickEffectKind)
                ? CursorPulse.scale(at: t, clicks: instruction.clickTimes) : 1.0
            cursor = CursorFrame(image: image, point: sample.point,
                                 sizeFraction: instruction.cursorSize * pulse, hotspot: hotspot)
            clickRings = ClickEffects.rings(at: t, clicks: instruction.clickEvents,
                                            kind: clickEffectKind)
            if clickEffectKind == .sparkle {
                clickSpokes = ClickEffects.spokes(at: t, clicks: instruction.clickEvents)
            }
        }
        let rendered = compositor.render(
            RenderInputs(screen: screenImage, webcam: webcamImage,
                         backgroundImage: instruction.backgroundImage),
            settings: instruction.settings, canvasSize: canvasSize, zoom: zoom, cursor: cursor,
            blurBoxes: BlurBoxSpec.active(instruction.blurBoxes, at: t),
            annotations: AnnotationSpec.active(instruction.annotations, at: t),
            tilt: tilt, clickEffectKind: clickEffectKind, clickRings: clickRings,
            clickSpokes: clickSpokes, cameraVelocity: camVel)
        context.render(rendered, to: output)
        request.finish(withComposedVideoFrame: output)
    }
}
