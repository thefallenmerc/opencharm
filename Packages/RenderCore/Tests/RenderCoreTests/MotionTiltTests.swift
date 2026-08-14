import CoreImage
import XCTest
@testable import RenderCore

final class MotionTiltTests: XCTestCase {
    // MARK: fixtures

    /// 60 Hz samples marching right at `speed` normalized units/sec from t = 0. Sample times are
    /// built as `Double(i) / hz` so a query at the same expression is bitwise-equal to a sample
    /// time — the closed-form assertions below need the window boundary to land exactly.
    private func rightwardTrack(speed: Double, seconds: Double, hz: Double = 60) -> [CursorSample] {
        let n = Int((seconds * hz).rounded())
        return (0...n).map { i in
            let t = Double(i) / hz
            return CursorSample(time: t, point: CGPoint(x: 0.1 + speed * t, y: 0.5))
        }
    }

    private func downwardTrack(speed: Double, seconds: Double, hz: Double = 60) -> [CursorSample] {
        let n = Int((seconds * hz).rounded())
        return (0...n).map { i in
            let t = Double(i) / hz
            return CursorSample(time: t, point: CGPoint(x: 0.5, y: 0.1 + speed * t))
        }
    }

    // MARK: CursorTrack.velocity

    func testVelocityIsZeroWithoutEnoughSamples() {
        XCTAssertEqual(CursorTrack.velocity(at: 1, samples: []), .zero)
        XCTAssertEqual(CursorTrack.velocity(
            at: 1, samples: [CursorSample(time: 0, point: CGPoint(x: 0.2, y: 0.3))]), .zero)
    }

    func testVelocityIsZeroForAStaticPointer() {
        let track = (0...120).map {
            CursorSample(time: Double($0) / 60, point: CGPoint(x: 0.4, y: 0.6))
        }
        let v = CursorTrack.velocity(at: 1, samples: track)
        XCTAssertEqual(v.dx, 0, accuracy: 1e-12)
        XCTAssertEqual(v.dy, 0, accuracy: 1e-12)
    }

    func testVelocityIsZeroWhenTheWindowPredatesEverySample() {
        // Every sample is in the future of `t` → the filter has nothing to fold, still at rest.
        let track = rightwardTrack(speed: 0.8, seconds: 1)
        XCTAssertEqual(CursorTrack.velocity(at: -0.5, samples: track), .zero)
    }

    /// Folding a CONSTANT raw velocity `V` through the one-pole filter from rest has an exact
    /// closed form: the per-step factors telescope, so after `T` seconds v = V·(1 − e^(−T/τ)),
    /// independent of the sample rate. That is the contract this filter must honour.
    func testVelocityRisesTowardConstantSpeedOnTheClosedForm() {
        let speed = 0.6, tau = 0.25
        let track = rightwardTrack(speed: speed, seconds: 1)
        for elapsed in [0.25, 0.5, 1.0] {
            let v = CursorTrack.velocity(at: elapsed, samples: track, tau: tau)
            XCTAssertEqual(v.dx, speed * (1 - exp(-elapsed / tau)), accuracy: 1e-3,
                           "one-pole rise mismatch at T = \(elapsed)")
            XCTAssertEqual(v.dy, 0, accuracy: 1e-9)
            XCTAssertLessThan(v.dx, speed, "the filter must never overshoot the raw speed")
        }
    }

    func testVelocityDecaysTowardRestAfterTheLastSample() {
        let speed = 0.6, tau = 0.25
        let track = rightwardTrack(speed: speed, seconds: 0.5)
        let atEnd = CursorTrack.velocity(at: 0.5, samples: track, tau: tau)
        let oneTauLater = CursorTrack.velocity(at: 0.5 + tau, samples: track, tau: tau)
        XCTAssertEqual(oneTauLater.dx, atEnd.dx * exp(-1), accuracy: 1e-3)
        XCTAssertLessThan(oneTauLater.dx, atEnd.dx)
        // Far past the track the pointer has been at rest longer than the horizon → exactly zero.
        XCTAssertEqual(CursorTrack.velocity(at: 20, samples: track, tau: tau), .zero)
    }

    /// Frames render out of order on a concurrent queue: the same `t` must give the same answer
    /// no matter which times were queried before it. (Stateless by construction — asserted.)
    func testVelocityIsDeterministicUnderOutOfOrderQueries() {
        let track = rightwardTrack(speed: 0.9, seconds: 2)
        let first = CursorTrack.velocity(at: 0.37, samples: track)
        for probe in [1.9, 0.01, 1.0, 0.37, 5.0, 0.2] {
            _ = CursorTrack.velocity(at: probe, samples: track)
        }
        let again = CursorTrack.velocity(at: 0.37, samples: track)
        XCTAssertEqual(first.dx, again.dx)
        XCTAssertEqual(first.dy, again.dy)
    }

    /// Only the last `horizon` seconds matter: an ancient burst of motion cannot leak into `t`.
    func testVelocityWindowIsBoundedByTheHorizon() {
        var track = rightwardTrack(speed: 2.0, seconds: 0.5)
        track += (1...60).map { CursorSample(time: 10 + Double($0) / 60, point: track.last!.point) }
        XCTAssertEqual(CursorTrack.velocity(at: 11, samples: track, horizon: 2.0), .zero)
    }

    // MARK: MotionTilt.state gating

    func testStateIsIdentityWhenTheFeatureIsOff() {
        let track = rightwardTrack(speed: 1.0, seconds: 1)
        let on = Motion3DSettings(enabled: true, strength: 1)
        XCTAssertEqual(MotionTilt.state(at: 1, samples: track, zoomProgress: 1, settings: nil),
                       .identity)
        XCTAssertEqual(MotionTilt.state(at: 1, samples: track, zoomProgress: 1,
                                        settings: Motion3DSettings(enabled: false, strength: 1)),
                       .identity)
        XCTAssertEqual(MotionTilt.state(at: 1, samples: track, zoomProgress: 0, settings: on),
                       .identity)
        XCTAssertEqual(MotionTilt.state(at: 1, samples: track, zoomProgress: 1,
                                        settings: Motion3DSettings(enabled: true, strength: 0)),
                       .identity)
        // …and NOT identity once every gate is open.
        XCTAssertFalse(MotionTilt.state(at: 1, samples: track, zoomProgress: 1,
                                        settings: on).isIdentity)
    }

    func testStateMagnitudeClampsAtExtremeVelocity() {
        let track = rightwardTrack(speed: 500, seconds: 1)
        let settings = Motion3DSettings(enabled: true, strength: 0.5)
        let tilt = MotionTilt.state(at: 1, samples: track, zoomProgress: 0.8, settings: settings)
        let cap = MotionTilt.maxRadians * 0.5 * 0.8
        XCTAssertEqual(tilt.yaw, cap, accuracy: 1e-12, "saturates at exactly the capped deflection")
        XCTAssertLessThanOrEqual(abs(tilt.yaw), cap + 1e-12)
        XCTAssertLessThanOrEqual(abs(tilt.pitch), cap + 1e-12)
    }

    func testStateScalesWithStrengthAndZoomProgress() {
        let track = rightwardTrack(speed: 500, seconds: 1)
        let full = MotionTilt.state(at: 1, samples: track, zoomProgress: 1,
                                    settings: Motion3DSettings(enabled: true, strength: 1))
        let half = MotionTilt.state(at: 1, samples: track, zoomProgress: 0.5,
                                    settings: Motion3DSettings(enabled: true, strength: 1))
        XCTAssertEqual(half.yaw, full.yaw / 2, accuracy: 1e-12)
        XCTAssertEqual(full.yaw, MotionTilt.maxRadians, accuracy: 1e-12)
    }

    /// Sign convention, asserted through the geometry it is supposed to produce (not just the
    /// scalar): pointer right ⇒ the RIGHT edge recedes; pointer up ⇒ the TOP edge recedes.
    func testStateSignsLeanTheCardAwayFromTheDirectionOfTravel() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let on = Motion3DSettings(enabled: true, strength: 1)

        let right = MotionTilt.state(at: 1, samples: rightwardTrack(speed: 500, seconds: 1),
                                     zoomProgress: 1, settings: on)
        XCTAssertGreaterThan(right.yaw, 0)
        XCTAssertEqual(right.pitch, 0, accuracy: 1e-12)
        let rightCorners = MotionTilt.tiltedCorners(rect: rect, tilt: right)
        XCTAssertLessThan(rightCorners.tr.x, rect.maxX, "right edge must recede (shrink inward)")
        XCTAssertLessThan(rightCorners.tl.x, rect.minX, "left edge must advance (grow outward)")

        // Moving DOWN the screen: recorded dy is top-left-origin, so dy > 0 ⇒ pitch < 0 ⇒ the
        // BOTTOM edge recedes.
        let down = MotionTilt.state(at: 1, samples: downwardTrack(speed: 500, seconds: 1),
                                    zoomProgress: 1, settings: on)
        XCTAssertLessThan(down.pitch, 0)
        let downCorners = MotionTilt.tiltedCorners(rect: rect, tilt: down)
        XCTAssertGreaterThan(downCorners.bl.y, rect.minY, "bottom edge must recede")
        XCTAssertGreaterThan(downCorners.tl.y, rect.maxY, "top edge must advance")
    }

    // MARK: MotionTilt.tiltedCorners

    func testTiltedCornersAreExactUnderIdentity() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let c = MotionTilt.tiltedCorners(rect: rect, tilt: .identity)
        XCTAssertEqual(c.tl, CGPoint(x: rect.minX, y: rect.maxY))
        XCTAssertEqual(c.tr, CGPoint(x: rect.maxX, y: rect.maxY))
        XCTAssertEqual(c.bl, CGPoint(x: rect.minX, y: rect.minY))
        XCTAssertEqual(c.br, CGPoint(x: rect.maxX, y: rect.minY))
    }

    func testPureYawKeepsVerticalSymmetryAndShrinksTheRecedingEdge() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let c = MotionTilt.tiltedCorners(rect: rect, tilt: TiltState(yaw: 0.3, pitch: 0))
        // Each vertical edge stays vertical (yaw rotates about the vertical centre axis)…
        XCTAssertEqual(c.tr.x, c.br.x, accuracy: 1e-9)
        XCTAssertEqual(c.tl.x, c.bl.x, accuracy: 1e-9)
        // …and stays mirrored about the horizontal centre line (no pitch).
        XCTAssertEqual(c.tr.y - rect.midY, rect.midY - c.br.y, accuracy: 1e-9)
        XCTAssertEqual(c.tl.y - rect.midY, rect.midY - c.bl.y, accuracy: 1e-9)
        // Right edge recedes: pulled toward the centre and shortened.
        XCTAssertLessThan(c.tr.x, rect.maxX)
        XCTAssertLessThan(c.tr.y, rect.maxY)
        // Left edge advances: pushed away from the centre and lengthened.
        XCTAssertLessThan(c.tl.x, rect.minX)
        XCTAssertGreaterThan(c.tl.y, rect.maxY)
    }

    func testPureNegativeYawMirrorsPureYaw() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let plus = MotionTilt.tiltedCorners(rect: rect, tilt: TiltState(yaw: 0.3, pitch: 0))
        let minus = MotionTilt.tiltedCorners(rect: rect, tilt: TiltState(yaw: -0.3, pitch: 0))
        XCTAssertEqual(rect.midX - plus.tl.x, minus.tr.x - rect.midX, accuracy: 1e-9)
        XCTAssertEqual(plus.tl.y, minus.tr.y, accuracy: 1e-9)
    }

    func testPurePitchKeepsHorizontalSymmetryAndShrinksTheRecedingEdge() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let c = MotionTilt.tiltedCorners(rect: rect, tilt: TiltState(yaw: 0, pitch: 0.3))
        XCTAssertEqual(c.tl.y, c.tr.y, accuracy: 1e-9)
        XCTAssertEqual(c.bl.y, c.br.y, accuracy: 1e-9)
        XCTAssertEqual(rect.midX - c.tl.x, c.tr.x - rect.midX, accuracy: 1e-9)
        // Top edge recedes: narrower and pulled down toward the centre.
        XCTAssertLessThan(c.tr.x, rect.maxX)
        XCTAssertLessThan(c.tr.y, rect.maxY)
        // Bottom edge advances: wider than the untilted edge.
        XCTAssertGreaterThan(c.br.x, rect.maxX)
        // The near half must stay TALLER than the far half — that asymmetry is the perspective
        // signature. (At this deliberately exaggerated 0.3 rad the cos foreshortening of the
        // short axis outweighs the perspective growth, so the near edge still nets slightly
        // inward in absolute terms; at the ≤4° this feature actually produces, perspective —
        // O(θ) — dominates the cos term — O(θ²) — and it moves outward.)
        XCTAssertGreaterThan(rect.midY - c.br.y, c.tr.y - rect.midY)
    }

    func testTiltedCornersToleratesADegenerateRect() {
        let rect = CGRect(x: 5, y: 5, width: 0, height: 0)
        let c = MotionTilt.tiltedCorners(rect: rect, tilt: TiltState(yaw: 0.3, pitch: 0.2))
        XCTAssertEqual(c.tl, CGPoint(x: 5, y: 5))
        XCTAssertEqual(c.br, CGPoint(x: 5, y: 5))
    }

    // MARK: render — identity fast path

    private let canvas = CGSize(width: 400, height: 260)

    private func screen() -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
    }

    private func cursorImage() -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    private func loadedSettings() -> RenderSettings {
        var s = RenderSettings.default
        s.background = .solid(RGBAColor(r: 1, g: 1, b: 1))
        s.webcam.visible = false
        return s
    }

    private var boxes: [BlurBoxSpec] {
        [BlurBoxSpec(id: "b", start: 0, end: 1,
                     rect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2))]
    }

    private var annotations: [AnnotationSpec] {
        [AnnotationSpec(id: "r", kind: "rectangle", start: 0, end: 1,
                        rect: CGRect(x: 0.1, y: 0.1, width: 0.25, height: 0.2)),
         AnnotationSpec(id: "t", kind: "text", start: 0, end: 1,
                        rect: CGRect(x: 0.5, y: 0.6, width: 0.3, height: 0.1), text: "hello"),
         AnnotationSpec(id: "s", kind: "spotlight", start: 0, end: 1,
                        rect: CGRect(x: 0.55, y: 0.2, width: 0.2, height: 0.2))]
    }

    /// The whole contract of this feature: an identity tilt must take the pre-existing code path,
    /// so a loaded frame (blur boxes + every annotation kind + cursor + zoom) renders exactly what
    /// the default-argument call renders.
    func testIdentityTiltRendersExactlyTheUntiltedFrame() {
        let c = Compositor()
        let s = loadedSettings()
        let cf = CursorFrame(image: cursorImage(), point: CGPoint(x: 0.45, y: 0.55),
                             sizeFraction: 0.08)
        let zoom = ZoomState(scale: 1.6, focus: CGPoint(x: 0.4, y: 0.45), progress: 1)
        func frame(_ tilt: TiltState?) -> CGImage {
            let img = tilt.map {
                c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                         zoom: zoom, cursor: cf, blurBoxes: boxes, annotations: annotations,
                         tilt: $0)
            } ?? c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                          zoom: zoom, cursor: cf, blurBoxes: boxes, annotations: annotations)
            return GoldenAssert.cgImage(img)
        }
        let base = frame(nil)
        XCTAssertLessThan(GoldenAssert.meanAbsDiff(base, frame(.identity)), 0.001,
                          "tilt: .identity must not perturb a single pixel")
        // A tilt below the identity threshold is a sub-pixel no-op → same fast path.
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(base, frame(TiltState(yaw: 5e-5, pitch: -5e-5))), 0.001,
            "sub-threshold tilt must also take the flat path")
    }

    // MARK: render — tilt path

    /// Mean sRGB of a region of the rendered frame (CGImage coords: row 0 is the TOP).
    private func meanColor(_ img: CGImage, _ r: CGRect) -> (r: Double, g: Double, b: Double) {
        let sub = img.cropping(to: r)!
        var data = [UInt8](repeating: 0, count: sub.width * sub.height * 4)
        let ctx = CGContext(data: &data, width: sub.width, height: sub.height,
                            bitsPerComponent: 8, bytesPerRow: sub.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: sub.width, height: sub.height))
        var sum = (0.0, 0.0, 0.0)
        for i in stride(from: 0, to: data.count, by: 4) {
            sum.0 += Double(data[i]); sum.1 += Double(data[i + 1]); sum.2 += Double(data[i + 2])
        }
        let n = Double(sub.width * sub.height) * 255
        return (sum.0 / n, sum.1 / n, sum.2 / n)
    }

    /// Canvas 400×260 with a 320×200 screen and 6% padding fits to height:
    /// contentRect = (16.96, 15.6, 366.08, 228.8) — its right edge sits at x ≈ 383.
    /// A strong yaw pulls that edge in to x ≈ 347, so a probe at x ≈ 355–370 flips from the
    /// screen's blue to the background's white.
    func testStrongYawPullsTheCardsRightEdgeInward() {
        let c = Compositor()
        var s = loadedSettings()
        s.shadow.opacity = 0 // keep the probe purely card-vs-background
        let probe = CGRect(x: 355, y: 110, width: 15, height: 40)

        let flat = GoldenAssert.cgImage(c.render(
            RenderInputs(screen: screen()), settings: s, canvasSize: canvas))
        let tilted = GoldenAssert.cgImage(c.render(
            RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
            tilt: TiltState(yaw: 0.5, pitch: 0)))

        let flatColor = meanColor(flat, probe)
        XCTAssertGreaterThan(flatColor.b, 0.8, "probe must sit on the blue card when flat")
        XCTAssertLessThan(flatColor.r, 0.2)
        let tiltedColor = meanColor(tilted, probe)
        XCTAssertGreaterThan(tiltedColor.r, 0.8, "yawed card must have receded past the probe")
        XCTAssertGreaterThan(tiltedColor.g, 0.8)
    }

    /// The card is warped as a PADDED crop, because `CIPerspectiveTransform` maps its input's
    /// extent corners — so the compositor hands it the padded rect's corners, projected through
    /// the same camera. That is only correct because the projection is a homography. This pins it
    /// down end to end: the rendered content edge must land exactly where the public
    /// `tiltedCorners(rect: contentRect,)` says it should, padding and all.
    func testWarpedContentEdgeLandsOnTheProjectedContentCorner() {
        let c = Compositor()
        var s = loadedSettings()
        s.shadow.opacity = 0
        let tilt = TiltState(yaw: 0.5, pitch: 0)
        let layout = CanvasLayout.compute(canvasSize: canvas, screenAspect: 320.0 / 200.0,
                                          settings: s)
        // Pure yaw ⇒ the right edge stays a vertical line, so tr.x is the edge at every row.
        let expected = MotionTilt.tiltedCorners(rect: layout.contentRect, tilt: tilt).tr.x

        let img = GoldenAssert.cgImage(c.render(RenderInputs(screen: screen()),
                                                settings: s, canvasSize: canvas, tilt: tilt))
        // Walk the middle row inward from the canvas edge to the first card pixel. The card is
        // pure blue and the background pure white, so RED is what separates them (both are
        // blue = 1).
        let row = CGFloat(canvas.height / 2)
        var edge: CGFloat?
        for x in stride(from: CGFloat(canvas.width) - 1, through: 0, by: -1) {
            if meanColor(img, CGRect(x: x, y: row, width: 1, height: 1)).r < 0.5 {
                edge = x + 1 // the boundary sits just past the last card pixel
                break
            }
        }
        let found = try! XCTUnwrap(edge)
        XCTAssertEqual(found, expected, accuracy: 2,
                       "warped content edge (\(found)) must match the projected corner (\(expected))")
    }

    /// The tilt path must produce the same opaque, canvas-sized output contract as the flat one,
    /// with every content-anchored layer (blurs, annotations, cursor) still present.
    func testTiltPathKeepsTheCanvasContractWithEveryLayerPresent() {
        let c = Compositor()
        let s = loadedSettings()
        let cf = CursorFrame(image: cursorImage(), point: CGPoint(x: 0.45, y: 0.55),
                             sizeFraction: 0.08)
        let tilt = TiltState(yaw: 0.12, pitch: -0.08)
        let out = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                           zoom: ZoomState(scale: 1.4, focus: CGPoint(x: 0.5, y: 0.5), progress: 1),
                           cursor: cf, blurBoxes: boxes, annotations: annotations, tilt: tilt)
        XCTAssertEqual(out.extent, CGRect(origin: .zero, size: canvas))
        let flat = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                            zoom: ZoomState(scale: 1.4, focus: CGPoint(x: 0.5, y: 0.5), progress: 1),
                            cursor: cf, blurBoxes: boxes, annotations: annotations)
        XCTAssertGreaterThan(
            GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(out), GoldenAssert.cgImage(flat)), 0.001,
            "a real tilt must change the frame")
    }

    /// Rendering the same tilted frame twice (shared Compositor, so the sprite/mask caches are
    /// warm on the second pass) must be bit-stable — the concurrent render queue depends on it.
    func testTiltedRenderIsRepeatable() {
        let c = Compositor()
        let s = loadedSettings()
        let tilt = TiltState(yaw: 0.2, pitch: 0.1)
        func once() -> CGImage {
            GoldenAssert.cgImage(c.render(
                RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                annotations: annotations, tilt: tilt))
        }
        XCTAssertEqual(GoldenAssert.meanAbsDiff(once(), once()), 0, accuracy: 1e-12)
    }

    // MARK: settings persistence

    func testMotion3DSettingsRoundTripAndLegacyDecode() throws {
        XCTAssertNil(RenderSettings.default.motion3D, "off unless a project opts in")
        let decoded = try JSONDecoder().decode(
            RenderSettings.self, from: JSONEncoder().encode(RenderSettings.default))
        XCTAssertNil(decoded.motion3D)

        var s = RenderSettings.default
        s.motion3D = Motion3DSettings(enabled: true, strength: 0.75)
        let back = try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.motion3D, s.motion3D)
    }
}
