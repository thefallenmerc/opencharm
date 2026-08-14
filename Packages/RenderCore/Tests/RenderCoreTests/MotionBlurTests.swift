import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import RenderCore

final class MotionBlurTests: XCTestCase {
    // MARK: CameraVelocity.between

    func testBetweenComputesTheFiniteDifference() {
        let a = ZoomState(scale: 1.0, focus: CGPoint(x: 0.2, y: 0.3), progress: 0)
        let b = ZoomState(scale: 1.5, focus: CGPoint(x: 0.3, y: 0.5), progress: 1)
        let v = CameraVelocity.between(a, b, dt: 0.5)
        XCTAssertEqual(v.focusRate.dx, 0.2, accuracy: 1e-12) // (0.3 - 0.2) / 0.5
        XCTAssertEqual(v.focusRate.dy, 0.4, accuracy: 1e-12) // (0.5 - 0.3) / 0.5
        XCTAssertEqual(v.scaleRate, 1.0, accuracy: 1e-12)    // (1.5 - 1.0) / 0.5
    }

    func testBetweenIsZeroForIdenticalStates() {
        let s = ZoomState(scale: 1.6, focus: CGPoint(x: 0.4, y: 0.4), progress: 1)
        XCTAssertEqual(CameraVelocity.between(s, s, dt: 1.0 / 60), .zero)
    }

    func testBetweenIsZeroForNonPositiveDt() {
        let a = ZoomState(scale: 1.0, focus: CGPoint(x: 0, y: 0), progress: 0)
        let b = ZoomState(scale: 2.0, focus: CGPoint(x: 1, y: 1), progress: 1)
        XCTAssertEqual(CameraVelocity.between(a, b, dt: 0), .zero)
        XCTAssertEqual(CameraVelocity.between(a, b, dt: -0.5), .zero)
    }

    // MARK: render fixtures

    private let canvas = CGSize(width: 400, height: 260)

    /// A fine checkerboard, not a single seam: gives both directional and zoom blur plenty of
    /// local edges to smear no matter where the pan direction or zoom focus/center land — a flat
    /// color, or a lone seam far from the blur's center, would look identical blurred or not.
    private func screen() -> CIImage {
        let f = CIFilter.checkerboardGenerator()
        f.center = CGPoint(x: 160, y: 100)
        f.color0 = CIColor(red: 1, green: 0, blue: 0)
        f.color1 = CIColor(red: 0, green: 0, blue: 1)
        f.width = 20
        f.sharpness = 1
        return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
    }

    private func webcam() -> CIImage {
        CIImage(color: CIColor(red: 0.1, green: 0.9, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
    }

    private func settings(motionBlur: Double?) -> RenderSettings {
        var s = RenderSettings.default
        s.background = .solid(RGBAColor(r: 1, g: 1, b: 1))
        s.shadow.opacity = 0
        s.motionBlur = motionBlur
        return s
    }

    private let panZoom = ZoomState(scale: 1.6, focus: CGPoint(x: 0.5, y: 0.5), progress: 1)

    /// A brisk pan: well above the 80 px/s directional-blur gate at this canvas/zoom size
    /// (contentRect width ≈ 366 px, scale 1.6 ⇒ ≈ 586 px/s).
    private let panningVelocity = CameraVelocity(focusRate: CGVector(dx: 1.0, dy: 0), scaleRate: 0)
    /// A brisk scale ramp: well above the 0.5/s zoom-blur gate.
    private let rampingVelocity = CameraVelocity(focusRate: .zero, scaleRate: 3.0)

    private func cg(_ image: CIImage) -> CGImage { GoldenAssert.cgImage(image) }

    // MARK: identity contract

    /// `motionBlur == nil` must ignore any velocity entirely — the guard lives before the filter
    /// pipeline is even reached, so a project with the feature off renders exactly what it did
    /// before this feature existed, no matter how the camera happens to be moving.
    func testNilAmountIgnoresVelocityEntirely() {
        let c = Compositor()
        let s = settings(motionBlur: nil)
        let withVelocity = c.render(RenderInputs(screen: screen()), settings: s,
                                    canvasSize: canvas, zoom: panZoom,
                                    cameraVelocity: CameraVelocity(focusRate: CGVector(dx: 5, dy: 5),
                                                                   scaleRate: 5))
        let withoutVelocity = c.render(RenderInputs(screen: screen()), settings: s,
                                       canvasSize: canvas, zoom: panZoom)
        XCTAssertEqual(GoldenAssert.meanAbsDiff(cg(withVelocity), cg(withoutVelocity)), 0,
                       accuracy: 1e-12)
    }

    /// A sub-threshold amount (below the 0.005 the panel's slider already floors to `nil`) must
    /// also take the untouched path, matching the panel's own nil-below-0.005 idiom.
    func testNearZeroAmountRendersIdenticallyToNil() {
        let c = Compositor()
        let nilFrame = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: nil),
                                canvasSize: canvas, zoom: panZoom, cameraVelocity: panningVelocity)
        let tinyFrame = c.render(RenderInputs(screen: screen()),
                                 settings: settings(motionBlur: 0.001),
                                 canvasSize: canvas, zoom: panZoom, cameraVelocity: panningVelocity)
        XCTAssertEqual(GoldenAssert.meanAbsDiff(cg(nilFrame), cg(tinyFrame)), 0, accuracy: 1e-12)
    }

    /// A held zoom — two identical `ZoomState`s, so the finite-difference velocity is exactly
    /// zero — must render identically even with the amount turned all the way up: only actual
    /// motion (pan or scale ramp) may perturb a pixel.
    func testZeroVelocityHoldRendersIdenticallyRegardlessOfAmount() {
        let c = Compositor()
        let vel = CameraVelocity.between(panZoom, panZoom, dt: 1.0 / 60)
        XCTAssertEqual(vel, .zero)
        let held = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: 0.9),
                            canvasSize: canvas, zoom: panZoom, cameraVelocity: vel)
        let baseline = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: nil),
                                canvasSize: canvas, zoom: panZoom)
        XCTAssertEqual(GoldenAssert.meanAbsDiff(cg(held), cg(baseline)), 0, accuracy: 1e-12)
    }

    /// Velocity that is present but below both gates (a slow drift, not a "camera operator" pan
    /// or ramp) must also fall through untouched — the blur is meant to be exclusive to actual
    /// fast motion, never a constant low-level softening.
    func testSubThresholdVelocityRendersIdentically() {
        let c = Compositor()
        let slow = CameraVelocity(focusRate: CGVector(dx: 0.01, dy: 0), scaleRate: 0.1)
        let untouched = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: 1),
                                 canvasSize: canvas, zoom: panZoom, cameraVelocity: slow)
        let baseline = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: nil),
                                canvasSize: canvas, zoom: panZoom)
        XCTAssertEqual(GoldenAssert.meanAbsDiff(cg(untouched), cg(baseline)), 0, accuracy: 1e-12)
    }

    // MARK: real motion

    /// A brisk pan must visibly smear the seam, and the webcam bubble — composited AFTER the
    /// blur, at a constant size — must stay pixel-identical either way.
    func testPanBlurDiffersMeasurablyAndLeavesTheWebcamUntouched() {
        let c = Compositor()
        let s = settings(motionBlur: 1.0)
        let blurred = c.render(RenderInputs(screen: screen(), webcam: webcam()), settings: s,
                               canvasSize: canvas, zoom: panZoom, cameraVelocity: panningVelocity)
        let unblurred = c.render(RenderInputs(screen: screen(), webcam: webcam()),
                                 settings: settings(motionBlur: nil), canvasSize: canvas,
                                 zoom: panZoom)
        let diff = GoldenAssert.meanAbsDiff(cg(blurred), cg(unblurred))
        XCTAssertGreaterThan(diff, 0.01, "a brisk pan at full amount must visibly smear the seam")

        let layout = CanvasLayout.compute(canvasSize: canvas, screenAspect: 320.0 / 200.0,
                                          settings: s)
        // Probe well inside the bubble (inset from its edge) to dodge any antialiasing there —
        // this region must be untouched by the blur regardless of what happened to the content.
        let probeCI = layout.webcamRect.insetBy(dx: layout.webcamRect.width * 0.3,
                                                 dy: layout.webcamRect.height * 0.3)
        let probeCG = CGRect(x: probeCI.minX, y: canvas.height - probeCI.maxY,
                             width: probeCI.width, height: probeCI.height).integral
        let webcamDiff = GoldenAssert.meanAbsDiff(cg(blurred).cropping(to: probeCG)!,
                                                  cg(unblurred).cropping(to: probeCG)!)
        XCTAssertEqual(webcamDiff, 0, accuracy: 1e-6, "the webcam bubble must never blur")
    }

    /// A brisk scale ramp (zoom blur) must also visibly perturb the frame.
    func testZoomRampBlurDiffersMeasurably() {
        let c = Compositor()
        let s = settings(motionBlur: 1.0)
        let ramped = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                              zoom: panZoom, cameraVelocity: rampingVelocity)
        let flat = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: nil),
                            canvasSize: canvas, zoom: panZoom)
        let diff = GoldenAssert.meanAbsDiff(cg(ramped), cg(flat))
        XCTAssertGreaterThan(diff, 0.01, "a brisk scale ramp at full amount must visibly perturb")
    }

    /// Same inputs at a fixed instant must render bit-identically twice — the concurrent render
    /// queue depends on it, and CIFilter parameters (Float radius/amount/angle) must be derived
    /// the same way every call, not from any per-call mutable state.
    func testRenderIsDeterministic() {
        let c = Compositor()
        let s = settings(motionBlur: 0.7)
        func once() -> CGImage {
            cg(c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                       zoom: panZoom, cameraVelocity: panningVelocity))
        }
        XCTAssertEqual(GoldenAssert.meanAbsDiff(once(), once()), 0, accuracy: 1e-12)
    }

    /// End to end through the same evaluator the compositor uses: mid-way through a zoom's
    /// ease-in (a segment's `scale` is actively ramping via `ZoomTimeline.envelope`'s spring
    /// step), the finite-difference velocity straddling `t` is non-zero and perturbs the render —
    /// closing the loop from `ZoomTimeline.state` through `CameraVelocity.between` to the actual
    /// pixels, exactly as `CharmVideoCompositor.startRequest` wires it.
    func testSyntheticEaseInThroughTheEvaluatorProducesAVisibleBlur() {
        let eps = 1.0 / 120
        let segments = [ZoomSegment(start: 0, end: 5, easeIn: 1.0, easeOut: 1.0,
                                    focus: CGPoint(x: 0.5, y: 0.5), scale: 1.6)]
        let t = 0.3 // well inside the spring ease-in, where scale is changing fastest

        let zPrev = ZoomTimeline.state(at: t - eps, segments: segments)
        let zNext = ZoomTimeline.state(at: t + eps, segments: segments)
        let vel = CameraVelocity.between(zPrev, zNext, dt: 2 * eps)
        XCTAssertNotEqual(vel, .zero, "mid-ease-in the evaluator must report real scale motion")
        XCTAssertGreaterThan(abs(vel.scaleRate), 0.5, "ease-in ramps fast enough to clear the gate")

        let zoom = ZoomTimeline.state(at: t, segments: segments)
        let c = Compositor()
        let blurred = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: 1),
                               canvasSize: canvas, zoom: zoom, cameraVelocity: vel)
        let flat = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: nil),
                            canvasSize: canvas, zoom: zoom)
        XCTAssertGreaterThan(GoldenAssert.meanAbsDiff(cg(blurred), cg(flat)), 0.005)
    }

    // MARK: zoom-segment boundaries

    /// An OFF-CENTRE zoom — the case the end-to-end test above (focus 0.5, 0.5) cannot see.
    private let offCentre = [ZoomSegment(start: 1, end: 4, easeIn: 0.6, easeOut: 0.6,
                                         focus: CGPoint(x: 0.2, y: 0.25), scale: 2.0)]

    private func panOnly(_ v: CameraVelocity) -> CameraVelocity {
        CameraVelocity(focusRate: v.focusRate, scaleRate: 0)
    }

    /// `ZoomTimeline.state`'s focus is discontinuous at a segment edge (canvas centre outside, the
    /// segment's anchor one instant inside) while its scale is not. A raw finite difference
    /// straddling that edge therefore reports a pan of tens of units per second and pegs the
    /// directional blur at its 24 px radius cap — a full-frame smear on exactly one frame, at the
    /// start AND the end of every zoom. `CameraVelocity.sampled` drops the pan component there.
    func testFocusJumpAtASegmentEdgeIsNotReportedAsAPan() {
        let eps = CameraVelocity.sampleEps
        for t in [1.0, 4.0] { // the segment's start and its end
            let raw = CameraVelocity.between(ZoomTimeline.state(at: t - eps, segments: offCentre),
                                             ZoomTimeline.state(at: t + eps, segments: offCentre),
                                             dt: 2 * eps)
            XCTAssertGreaterThan(hypot(raw.focusRate.dx, raw.focusRate.dy), 10,
                                 "the hazard this fix exists for: a teleporting focus at t = \(t)")

            let v = CameraVelocity.sampled(at: t, segments: offCentre)
            XCTAssertEqual(v.focusRate.dx, 0, "no pan may be reported across the edge at t = \(t)")
            XCTAssertEqual(v.focusRate.dy, 0)
            XCTAssertEqual(v.scaleRate, raw.scaleRate, accuracy: 1e-12,
                           "scale is continuous across the edge — its rate must survive")
        }
    }

    /// The same boundary, in pixels: the frame at a zoom's first instant must render exactly like
    /// the no-blur frame, and the raw (unguarded) difference must be shown to smear it — otherwise
    /// this test would pass on a renderer that simply never blurs.
    func testSegmentEdgeFrameRendersWithoutASmearWithOffCentreFocus() {
        let c = Compositor()
        let t = 1.0
        let zoom = ZoomTimeline.state(at: t, segments: offCentre)
        func frame(_ v: CameraVelocity) -> CGImage {
            cg(c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: 1),
                        canvasSize: canvas, zoom: zoom, cameraVelocity: v))
        }
        let baseline = cg(c.render(RenderInputs(screen: screen()),
                                   settings: settings(motionBlur: nil),
                                   canvasSize: canvas, zoom: zoom))

        let raw = CameraVelocity.between(
            ZoomTimeline.state(at: t - CameraVelocity.sampleEps, segments: offCentre),
            ZoomTimeline.state(at: t + CameraVelocity.sampleEps, segments: offCentre),
            dt: 2 * CameraVelocity.sampleEps)
        XCTAssertGreaterThan(GoldenAssert.meanAbsDiff(frame(panOnly(raw)), baseline), 0.01,
                             "the unguarded pan rate smears the whole frame at the radius cap")

        let sampled = CameraVelocity.sampled(at: t, segments: offCentre)
        XCTAssertEqual(GoldenAssert.meanAbsDiff(frame(panOnly(sampled)), baseline), 0,
                       accuracy: 1e-12, "the guarded pan component must not touch a pixel")
        // And the whole velocity, not just its pan half: at the edge the scale rate is still
        // inside its own gate, so the boundary frame comes out untouched end to end.
        XCTAssertEqual(GoldenAssert.meanAbsDiff(frame(sampled), baseline), 0, accuracy: 1e-12)
    }

    /// Two segments that touch (`AutoZoom` trims overlaps to exactly this) hit the same trap with
    /// two different anchors — and the envelope is non-zero on BOTH sides of the shared edge, so a
    /// "is either sample outside a zoom" test would sail straight past it. The guard is
    /// same-segment identity, which catches it.
    func testTouchingSegmentsDropThePanAtTheirSharedEdge() {
        let segments = [ZoomSegment(start: 0, end: 2, easeIn: 0.6, easeOut: 0.6,
                                    focus: CGPoint(x: 0.2, y: 0.2), scale: 2),
                        ZoomSegment(start: 2, end: 4, easeIn: 0.6, easeOut: 0.6,
                                    focus: CGPoint(x: 0.8, y: 0.8), scale: 2)]
        let eps = CameraVelocity.sampleEps
        let prev = ZoomTimeline.state(at: 2 - eps, segments: segments)
        let next = ZoomTimeline.state(at: 2 + eps, segments: segments)
        XCTAssertGreaterThan(prev.progress, 0, "still inside the outgoing zoom")
        XCTAssertGreaterThan(next.progress, 0, "already inside the incoming one")
        XCTAssertGreaterThan(hypot(CameraVelocity.between(prev, next, dt: 2 * eps).focusRate.dx,
                                   CameraVelocity.between(prev, next, dt: 2 * eps).focusRate.dy),
                             10, "the anchors are far apart — a raw difference sees a huge pan")

        let v = CameraVelocity.sampled(at: 2, segments: segments)
        XCTAssertEqual(v.focusRate.dx, 0)
        XCTAssertEqual(v.focusRate.dy, 0)
    }

    /// The guard must not swallow real motion: a genuine pan between two focus keys, both probes
    /// inside the same segment, has to come through exactly as the raw difference computes it —
    /// and still smear the frame.
    func testSampledKeepsARealPanInsideOneSegment() {
        let segments = [ZoomSegment(start: 0, end: 6, easeIn: 0.6, easeOut: 0.6, scale: 2,
                                    focusKeys: [FocusKey(time: 1, point: CGPoint(x: 0.2, y: 0.25)),
                                                FocusKey(time: 2, point: CGPoint(x: 0.8, y: 0.75))])]
        let t = 2.1
        let eps = CameraVelocity.sampleEps
        let raw = CameraVelocity.between(ZoomTimeline.state(at: t - eps, segments: segments),
                                         ZoomTimeline.state(at: t + eps, segments: segments),
                                         dt: 2 * eps)
        let v = CameraVelocity.sampled(at: t, segments: segments)
        XCTAssertEqual(v.focusRate.dx, raw.focusRate.dx, accuracy: 1e-12)
        XCTAssertEqual(v.focusRate.dy, raw.focusRate.dy, accuracy: 1e-12)
        XCTAssertGreaterThan(hypot(v.focusRate.dx, v.focusRate.dy), 0.1, "the camera IS panning")

        let c = Compositor()
        let zoom = ZoomTimeline.state(at: t, segments: segments)
        let blurred = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: 1),
                               canvasSize: canvas, zoom: zoom, cameraVelocity: panOnly(v))
        let flat = c.render(RenderInputs(screen: screen()), settings: settings(motionBlur: nil),
                            canvasSize: canvas, zoom: zoom)
        XCTAssertGreaterThan(GoldenAssert.meanAbsDiff(cg(blurred), cg(flat)), 0.005,
                             "a real mid-segment pan must still blur")
    }

    /// Nothing anywhere near a zoom: both probes are outside every segment, the focus is the
    /// canvas centre at both, and the velocity is exactly zero — no accidental blur on a
    /// completely static stretch of timeline.
    func testSampledIsZeroBetweenZooms() {
        XCTAssertEqual(CameraVelocity.sampled(at: 8, segments: offCentre), .zero)
        XCTAssertEqual(CameraVelocity.sampled(at: 0.2, segments: offCentre), .zero)
    }
}
