import AVFoundation
import CoreImage
import XCTest
@testable import RenderCore

final class ClickEffectTests: XCTestCase {
    // MARK: - 1. Ripple ring: determinism + life-window gating.

    func testRippleRingLifeWindowGatingAndDeterminism() {
        let click = ClickEvent(time: 2.0, point: CGPoint(x: 0.3, y: 0.4))

        XCTAssertTrue(ClickEffects.rings(at: 1.9, clicks: [click], kind: .ripple).isEmpty,
                     "no ring before the click")
        let mid = ClickEffects.rings(at: 2.3, clicks: [click], kind: .ripple)
        XCTAssertEqual(mid.count, 1, "exactly one ring for one click during its life")
        XCTAssertEqual(mid[0].point, click.point)
        XCTAssertTrue(ClickEffects.rings(at: click.time + ClickEffects.rippleLife + 0.01,
                                        clicks: [click], kind: .ripple).isEmpty,
                     "no ring once the life window has elapsed")

        // Pure function of (t, clicks): same inputs, same output.
        let again = ClickEffects.rings(at: 2.3, clicks: [click], kind: .ripple)
        XCTAssertEqual(mid, again)
    }

    // MARK: - 2. Sonar: 3 rings staggered.

    func testSonarStaggeredRingsAndRadiiOrdering() {
        let click = ClickEvent(time: 1.0, point: CGPoint(x: 0.5, y: 0.5))
        // click + 0.2s: stagger 0.15, life 0.6 → ring0 (dt 0.2) and ring1 (dt 0.05) alive;
        // ring2 (dt -0.1) hasn't started yet.
        let rings = ClickEffects.rings(at: 1.2, clicks: [click], kind: .sonar)
        XCTAssertEqual(rings.count, 2)
        // Constructed in click order (i = 0, then 1): the more-progressed ring (larger dt) has
        // the larger radius.
        XCTAssertGreaterThan(rings[0].radius, rings[1].radius)
        for ring in rings { XCTAssertEqual(ring.point, click.point) }

        // Other kinds emit no sonar rings.
        XCTAssertTrue(ClickEffects.rings(at: 1.2, clicks: [click], kind: .ripple).count == 1)
        XCTAssertTrue(ClickEffects.rings(at: 1.2, clicks: [click], kind: .sparkle).isEmpty)
        XCTAssertTrue(ClickEffects.rings(at: 1.2, clicks: [click], kind: .spotlight).isEmpty)
        XCTAssertTrue(ClickEffects.rings(at: 1.2, clicks: [click], kind: .none).isEmpty)
    }

    // MARK: - 3. resolve() fallback + pulseEnabled() gating.

    func testResolveFallsBackToPulseAndPulseGating() {
        XCTAssertEqual(ClickEffectKind.resolve(nil), .pulse)
        XCTAssertEqual(ClickEffectKind.resolve("garbage2030"), .pulse)
        XCTAssertEqual(ClickEffectKind.resolve("none"), .none)
        XCTAssertEqual(ClickEffectKind.resolve("ripple"), .ripple)
        XCTAssertEqual(ClickEffectKind.resolve("sonar"), .sonar)
        XCTAssertEqual(ClickEffectKind.resolve("sparkle"), .sparkle)
        XCTAssertEqual(ClickEffectKind.resolve("spotlight"), .spotlight)

        XCTAssertFalse(ClickEffects.pulseEnabled(.none))
        for kind: ClickEffectKind in [.pulse, .ripple, .sonar, .sparkle, .spotlight] {
            XCTAssertTrue(ClickEffects.pulseEnabled(kind), "\(kind) must keep the pulse haptic")
        }
    }

    // MARK: - 4. Render probe: ripple pixels change near the ring radius, not far outside; the
    //           cursor-nil gate silences every effect.

    private func probeSettings() -> RenderSettings {
        var s = RenderSettings.default
        s.webcam.visible = false
        s.shadow.opacity = 0
        s.background = .solid(RGBAColor(r: 0, g: 0, b: 0))
        return s
    }

    private func probeScreen() -> CIImage {
        CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
    }

    func testRippleRingChangesPixelsNearRadiusNotFarOutside() {
        let c = Compositor()
        let canvas = CGSize(width: 1000, height: 650)
        let s = probeSettings()
        let layout = CanvasLayout.compute(canvasSize: canvas, screenAspect: 320.0 / 200.0,
                                          settings: s)
        let anchor = CGPoint(x: layout.contentRect.minX + 0.5 * layout.contentRect.width,
                             y: layout.contentRect.minY + 0.5 * layout.contentRect.height)

        let click = ClickEvent(time: 0, point: CGPoint(x: 0.5, y: 0.5))
        let rings = ClickEffects.rings(at: 0.3, clicks: [click], kind: .ripple)
        XCTAssertEqual(rings.count, 1)
        let radiusPx = CGFloat(rings[0].radius) * canvas.height

        // A tiny cursor art, parked away from the ring so it doesn't contaminate the probes.
        let cursorArt = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        let cursor = CursorFrame(image: cursorArt, point: CGPoint(x: 0.04, y: 0.04),
                                 sizeFraction: 0.02)

        let without = c.render(RenderInputs(screen: probeScreen()), settings: s, canvasSize: canvas,
                               cursor: cursor)
        let with = c.render(RenderInputs(screen: probeScreen()), settings: s, canvasSize: canvas,
                            cursor: cursor, clickEffectKind: .ripple, clickRings: rings)

        // Near the ring's stroke (its right edge) the two renders must differ.
        let nearRect = CGRect(x: anchor.x + radiusPx - 12, y: anchor.y - 12, width: 24, height: 24)
        let nearDiff = GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(without.cropped(to: nearRect)),
                                                GoldenAssert.cgImage(with.cropped(to: nearRect)))
        XCTAssertGreaterThan(nearDiff, 0.01, "ring stroke should be visible near its radius")

        // Well outside the ring's full extent, the two renders must be identical.
        let farRect = CGRect(x: anchor.x + radiusPx * 5, y: anchor.y - 12, width: 24, height: 24)
            .intersection(CGRect(origin: .zero, size: canvas))
        let farDiff = GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(without.cropped(to: farRect)),
                                               GoldenAssert.cgImage(with.cropped(to: farRect)))
        XCTAssertLessThan(farDiff, 0.001, "far outside the ring, nothing should change")
    }

    func testCursorNilGatesEveryClickEffect() {
        let c = Compositor()
        let canvas = CGSize(width: 400, height: 260)
        let s = probeSettings()
        let click = ClickEvent(time: 0, point: CGPoint(x: 0.5, y: 0.5))
        let rings = ClickEffects.rings(at: 0.1, clicks: [click], kind: .ripple)
        XCTAssertFalse(rings.isEmpty)

        // `cursor: nil` models a legacy recording with a baked-in system cursor
        // (`instruction.cursorArt == nil`) — every click effect must be silenced, not just pulse.
        let baseline = c.render(RenderInputs(screen: probeScreen()), settings: s, canvasSize: canvas,
                                cursor: nil)
        let withRingsButNoCursor = c.render(RenderInputs(screen: probeScreen()), settings: s,
                                            canvasSize: canvas, cursor: nil,
                                            clickEffectKind: .ripple, clickRings: rings)
        XCTAssertEqual(GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(baseline),
                                                GoldenAssert.cgImage(withRingsButNoCursor)),
                      0, accuracy: 0.0001)

        // Same gate for spotlight-follow: no cursor point, no dim.
        let withSpotlightButNoCursor = c.render(RenderInputs(screen: probeScreen()), settings: s,
                                                canvasSize: canvas, cursor: nil,
                                                clickEffectKind: .spotlight)
        XCTAssertEqual(GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(baseline),
                                                GoldenAssert.cgImage(withSpotlightButNoCursor)),
                      0, accuracy: 0.0001)
    }

    // MARK: - 5. Identity contract: nil/"pulse" renders byte-identical to the pre-Task-7 pipeline.

    func testPulseKindRendersByteIdenticalToPreEffectsPipeline() {
        let c = Compositor()
        let canvas = CGSize(width: 400, height: 260)
        let s = probeSettings()
        let point = CGPoint(x: 0.5, y: 0.5)
        let art = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        let clickTimes = [0.05]
        let t = 0.09 // mid-shrink, so the pulse actually engages

        // OLD pipeline: pulse always computed straight from CursorPulse, no click-effect params.
        let oldPulse = CursorPulse.scale(at: t, clicks: clickTimes)
        let oldFrame = CursorFrame(image: art, point: point, sizeFraction: 0.1 * oldPulse)
        let old = c.render(RenderInputs(screen: probeScreen()), settings: s, canvasSize: canvas,
                           cursor: oldFrame)

        // NEW pipeline: settings.clickEffect == nil resolves to .pulse; pulseEnabled(.pulse) keeps
        // the same CursorPulse call; rings(kind: .pulse) is empty, so clickEffectLayer no-ops.
        XCTAssertNil(s.clickEffect)
        let kind = ClickEffectKind.resolve(s.clickEffect)
        XCTAssertEqual(kind, .pulse)
        let newPulse = ClickEffects.pulseEnabled(kind) ? CursorPulse.scale(at: t, clicks: clickTimes) : 1.0
        XCTAssertEqual(newPulse, oldPulse)
        let newFrame = CursorFrame(image: art, point: point, sizeFraction: 0.1 * newPulse)
        let rings = ClickEffects.rings(at: t, clicks: [ClickEvent(time: 0.05, point: point)], kind: kind)
        XCTAssertTrue(rings.isEmpty)
        let new = c.render(RenderInputs(screen: probeScreen()), settings: s, canvasSize: canvas,
                           cursor: newFrame, clickEffectKind: kind, clickRings: rings, clickSpokes: [])

        XCTAssertEqual(GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(old), GoldenAssert.cgImage(new)),
                      0, accuracy: 0.0001)
    }

    // MARK: - 5b. Tilt path: the spotlight dim belongs to the flat stage, not the warped card.

    private func tiltCursorArt() -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    /// `image` with every RGB channel scaled by `factor` — what a full-canvas dim of
    /// `1 - factor` alpha black does to an already-opaque frame.
    private func scaledRGB(_ image: CIImage, _ factor: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
        ])
    }

    private func meanRGB(_ image: CIImage, _ rect: CGRect) -> (r: Double, g: Double, b: Double) {
        let cg = GoldenAssert.cgImage(image.cropped(to: rect))
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &data, width: cg.width, height: cg.height,
                            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var sum = (0.0, 0.0, 0.0)
        for i in stride(from: 0, to: data.count, by: 4) {
            sum.0 += Double(data[i]); sum.1 += Double(data[i + 1]); sum.2 += Double(data[i + 2])
        }
        let n = Double(cg.width * cg.height) * 255
        return (sum.0 / n, sum.1 / n, sum.2 / n)
    }

    /// Task 4 kept annotation spotlights off the tilt card because their dim covers the WHOLE
    /// canvas; the spotlight-follow dim has to live in the same place for the same reason. Dimming
    /// the mid-assembly card instead tinted the card's transparent gutter (a dark fringe on the
    /// warp, and a rectangular silhouette for the card's own drop shadow) and left the background
    /// undimmed, so the dim popped on and off as the tilt engaged.
    ///
    /// The contract asserted here is exactly what "a full-canvas dim" means: outside the hole, the
    /// spotlight frame is the undimmed frame times `1 - dimOpacity`, everywhere — background,
    /// gutter, card shadow and card interior alike — on the tilt path just as on the flat one.
    func testTiltPathSpotlightDimsTheWholeCanvasWithNoFringeOnTheCard() {
        let c = Compositor()
        let canvas = CGSize(width: 400, height: 260)
        var s = RenderSettings.default
        s.webcam.visible = false
        s.background = .solid(RGBAColor(r: 1, g: 1, b: 1))
        // Shadow deliberately left at its default 0.45: the card's silhouette shadow is derived
        // from the warped card's own alpha, so a dim baked into the gutter corrupts it too.
        XCTAssertGreaterThan(s.shadow.opacity, 0)
        let screen = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
        // Pointer parked bottom-right, so the spotlight hole is nowhere near the probe.
        let cursor = CursorFrame(image: tiltCursorArt(), point: CGPoint(x: 0.85, y: 0.85),
                                 sizeFraction: 0.02)
        let tilt = TiltState(yaw: 0.12, pitch: -0.08)

        func frame(_ kind: ClickEffectKind, _ tilt: TiltState) -> CIImage {
            c.render(RenderInputs(screen: screen), settings: s, canvasSize: canvas,
                     cursor: cursor, tilt: tilt, clickEffectKind: kind)
        }
        let lit = frame(.pulse, tilt)      // no dim at all
        let dimmed = frame(.spotlight, tilt)
        XCTAssertEqual(dimmed.extent, CGRect(origin: .zero, size: canvas),
                       "the tilt path must keep the canvas contract with the dim on")

        // A band up the canvas's left side (CI space is y-up): it crosses the background corner,
        // the card's transparent gutter, its drop shadow and its interior — every surface the old
        // code dimmed inconsistently — and is far from the bottom-right hole.
        let probe = CGRect(x: 0, y: 130, width: 60, height: 130)
        let expected = scaledRGB(lit, 0.55) // 1 - spotlightDimOpacity
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(dimmed.cropped(to: probe)),
                                     GoldenAssert.cgImage(expected.cropped(to: probe))), 0.002,
            "outside the hole the tilted spotlight frame must be a uniform dim of the lit frame")

        // Spelled out at the one probe the old code got most obviously wrong: the canvas corner is
        // pure background, nowhere near the card, and it must be dimmed.
        let corner = CGRect(x: 2, y: 246, width: 12, height: 12)
        let litCorner = meanRGB(lit, corner)
        XCTAssertGreaterThan(litCorner.r, 0.95, "the corner is the white background")
        let dimCorner = meanRGB(dimmed, corner)
        XCTAssertEqual(dimCorner.r, litCorner.r * 0.55, accuracy: 0.02,
                       "background outside the card must dim too, not just the card")

        // …and the flat path, whose behaviour must not have moved, satisfies the same contract.
        let flatLit = frame(.pulse, .identity)
        let flatDim = frame(.spotlight, .identity)
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(GoldenAssert.cgImage(flatDim.cropped(to: probe)),
                                     GoldenAssert.cgImage(scaledRGB(flatLit, 0.55)
                                        .cropped(to: probe))), 0.002,
            "flat-path expectation, unchanged")
    }

    // MARK: - 5c. Tilt path: the card's gutter has to fit a click ring at the content edge.

    /// The tilt card is cropped to `contentRect` + a gutter before the perspective warp, so
    /// anything past the gutter gets a straight clipped edge. The gutter used to be sized for the
    /// synthetic pointer alone (2.5 × its height ≈ 33 px here) while a ring reaches 0.09 × canvas
    /// height (≈ 58 px) past a click point that can sit exactly ON the content edge.
    func testTiltCardGutterFitsAClickRingAtTheContentEdge() {
        let c = Compositor()
        let canvas = CGSize(width: 1000, height: 650)
        var s = RenderSettings.default
        s.webcam.visible = false
        s.shadow.opacity = 0
        s.background = .solid(RGBAColor(r: 0, g: 0, b: 0))
        // A square screen leaves room on the canvas either side of the content for the ring.
        let screen = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12))
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let layout = CanvasLayout.compute(canvasSize: canvas, screenAspect: 1, settings: s)
        // Pointer small (the case that makes the old gutter too tight) and parked top-left.
        let cursor = CursorFrame(image: tiltCursorArt(), point: CGPoint(x: 0.05, y: 0.05),
                                 sizeFraction: 0.02)
        // A ring on the content's right edge, grown to just inside the reach the gutter now
        // guarantees. Built directly: `ClickEffects.rings` timing is covered above; what is under
        // test here is the renderer's clipping, at a radius the geometry really does produce.
        let radius = ClickEffects.maxReachRatio - 0.005
        let ring = ClickEffects.Ring(point: CGPoint(x: 1, y: 0.5), radius: radius, alpha: 0.9,
                                     lineWidth: 0.006)
        // A real tilt, but a shallow one: the ring must survive the crop, and staying near-flat
        // keeps the probe over the ring's stroke rather than chasing the warp.
        let tilt = TiltState(yaw: 0.01, pitch: 0)

        func frame(_ rings: [ClickEffects.Ring], _ tilt: TiltState) -> CGImage {
            GoldenAssert.cgImage(c.render(RenderInputs(screen: screen), settings: s,
                                          canvasSize: canvas, cursor: cursor, tilt: tilt,
                                          clickEffectKind: .ripple, clickRings: rings))
        }
        // An 8×6 window straddling the ring's outer stroke, ~50 px past the content edge — beyond
        // the pointer-sized gutter, inside the click-sized one.
        let reach = CGFloat(radius) * canvas.height
        let probe = CGRect(x: layout.contentRect.maxX + reach - 6,
                           y: canvas.height - layout.contentRect.midY - 3,
                           width: 8, height: 6).integral
        func diff(_ tilt: TiltState) -> Double {
            GoldenAssert.meanAbsDiff(frame([ring], tilt).cropping(to: probe)!,
                                     frame([], tilt).cropping(to: probe)!)
        }
        XCTAssertGreaterThan(diff(.identity), 0.01,
                             "sanity: the flat path draws the ring's outer stroke at the probe")
        XCTAssertGreaterThan(diff(tilt), 0.01,
                             "the tilt card's gutter must not clip the ring's far side")
    }

    // MARK: - 6. clickEvents remap parity with clickTimes through cuts + speed.

    func testClickEventsRemapMatchesClickTimesExactlyThroughCutsAndSpeed() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1),
                                                     seconds: 4)
        var settings = RenderSettings.default
        settings.webcam.visible = false
        settings.cuts = [CutRange(start: 1.0, end: 1.5)]
        settings.playbackSpeed = 1.5
        let clicks = [
            ClickEvent(time: 2.5, point: CGPoint(x: 0.8, y: 0.1)),
            ClickEvent(time: 0.5, point: CGPoint(x: 0.2, y: 0.3)),
            ClickEvent(time: 1.2, point: CGPoint(x: 0.6, y: 0.7)), // inside the cut
        ]

        let built = try await ProjectCompositionBuilder.build(
            timeline: MediaTimeline(screen: .init(url: screenURL, startOffset: 0), webcam: nil,
                                    audio: []),
            settings: settings, canvasSize: CGSize(width: 320, height: 240),
            backgroundImage: nil, clicks: clicks, retimeForExport: true)

        let instruction = try XCTUnwrap(built.videoComposition.instructions.first as? CharmInstruction)
        XCTAssertEqual(instruction.clickEvents.count, clicks.count)
        XCTAssertEqual(instruction.clickEvents.map(\.time), instruction.clickTimes,
                      "clickEvents and clickTimes must go through the exact same remap")

        // Points are untouched by the cut/speed remap; only pairing needs the same time-sort
        // both outputs were built from.
        let sortedOriginal = clicks.sorted { $0.time < $1.time }
        for (event, original) in zip(instruction.clickEvents, sortedOriginal) {
            XCTAssertEqual(event.point, original.point)
        }
    }

    // MARK: - RenderSettings additive decode (clickEffect).

    func testClickEffectDecodesNilOnLegacySettings() throws {
        var s = RenderSettings.default
        XCTAssertNil(s.clickEffect)
        s.clickEffect = "sparkle"
        let back = try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.clickEffect, "sparkle")
    }
}
