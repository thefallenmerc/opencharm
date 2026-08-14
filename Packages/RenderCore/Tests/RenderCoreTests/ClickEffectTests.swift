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
