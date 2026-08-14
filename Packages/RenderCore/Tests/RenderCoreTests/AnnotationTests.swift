import CoreImage
import XCTest
@testable import RenderCore

final class AnnotationTests: XCTestCase {
    // MARK: model

    func testCodableRoundTripPerKind() throws {
        let specs: [AnnotationSpec] = [
            AnnotationSpec(id: "t", kind: "text", start: 0, end: 2,
                          rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2),
                          color: RGBAColor(r: 1, g: 1, b: 1, a: 1), text: "hello",
                          fontSize: 0.06),
            AnnotationSpec(id: "r", kind: "rectangle", start: 0, end: 2,
                          rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2),
                          color: RGBAColor(r: 0, g: 1, b: 0, a: 1), strokeWidth: 0.01,
                          cornerRadius: 0.2, fillOpacity: 0.4),
            AnnotationSpec(id: "e", kind: "ellipse", start: 0, end: 2,
                          rect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2),
                          color: RGBAColor(r: 0, g: 0, b: 1, a: 1), fillOpacity: 0.1),
            AnnotationSpec(id: "a", kind: "arrow", start: 0, end: 2,
                          rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                          color: RGBAColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 0.02,
                          arrowStart: CGPoint(x: 0.1, y: 0.1), arrowEnd: CGPoint(x: 0.4, y: 0.4)),
            AnnotationSpec(id: "s", kind: "spotlight", start: 0, end: 2,
                          rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                          cornerRadius: 0.1, dimOpacity: 0.7),
        ]
        for spec in specs {
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(AnnotationSpec.self, from: data)
            XCTAssertEqual(decoded, spec, "round-trip mismatch for kind \(spec.kind)")
        }
    }

    func testUnknownKindRoundTripsAndIsSkippedByRenderer() throws {
        let json = """
        {"id":"x","kind":"sparkles2030","start":0,"end":1,
         "rect":[[0.1,0.1],[0.2,0.2]]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnnotationSpec.self, from: json)
        XCTAssertEqual(decoded.kind, "sparkles2030")
        XCTAssertNil(decoded.resolvedKind)

        // Re-encode preserves the raw kind string.
        let reencoded = try JSONDecoder().decode(AnnotationSpec.self,
                                                  from: JSONEncoder().encode(decoded))
        XCTAssertEqual(reencoded.kind, "sparkles2030")

        // Renderer skips it entirely: identical output with or without it.
        let s = RenderSettings.default
        let screen = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
        let canvas = CGSize(width: 400, height: 260)
        let without = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas))
        let with = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, annotations: [decoded]))
        XCTAssertLessThan(GoldenAssert.meanAbsDiff(without, with), 0.001,
                          "unknown-kind annotation must not affect rendering")
    }

    func testSettingsDecodeWithoutAnnotations() throws {
        // Manifests written before the feature must decode with annotations == nil.
        let data = try JSONEncoder().encode(RenderSettings.default)
        let decoded = try JSONDecoder().decode(RenderSettings.self, from: data)
        XCTAssertNil(decoded.annotations)
        // And round-trip once annotations exist.
        var s = RenderSettings.default
        s.annotations = [AnnotationSpec(id: "x", kind: "text", start: 0, end: 2,
                                        rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25),
                                        text: "hi")]
        let back = try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.annotations, s.annotations)
    }

    func testScaledRetimesOnlyTime() {
        let spec = AnnotationSpec(id: "a", kind: "rectangle", start: 2, end: 4,
                                  rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                                  color: RGBAColor(r: 1, g: 0, b: 0, a: 1),
                                  strokeWidth: 0.02, cornerRadius: 0.25, fillOpacity: 0.5)
        let s = spec.scaled(by: 0.5) // 2× speed
        XCTAssertEqual(s.start, 1, accuracy: 0.0001)
        XCTAssertEqual(s.end, 2, accuracy: 0.0001)
        XCTAssertEqual(s.rect, spec.rect)
        XCTAssertEqual(s.color, spec.color)
        XCTAssertEqual(s.strokeWidth, spec.strokeWidth)
        XCTAssertEqual(s.cornerRadius, spec.cornerRadius)
        XCTAssertEqual(s.fillOpacity, spec.fillOpacity)
    }

    func testActiveGating() {
        let spec = AnnotationSpec(id: "a", kind: "rectangle", start: 1, end: 3,
                                  rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        XCTAssertTrue(AnnotationSpec.active([spec], at: 0.5).isEmpty)
        XCTAssertEqual(AnnotationSpec.active([spec], at: 1).count, 1) // boundary inclusive
        XCTAssertEqual(AnnotationSpec.active([spec], at: 2).count, 1)
        XCTAssertEqual(AnnotationSpec.active([spec], at: 3).count, 1)
        XCTAssertTrue(AnnotationSpec.active([spec], at: 3.5).isEmpty)
    }

    // MARK: render probes

    private var plainScreen: CIImage {
        CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
    }

    private var plainSettings: RenderSettings {
        var s = RenderSettings.default
        s.background = .solid(RGBAColor(r: 0.95, g: 0.95, b: 0.95))
        s.webcam.visible = false
        s.shadow.opacity = 0
        return s
    }

    private func region(_ img: CGImage, _ r: CGRect) -> CGImage { img.cropping(to: r)! }

    /// Canvas 400×260, screen 320×200 (16:10, same aspect), padding 0.06*260=15.6 →
    /// content ≈ 368.6×230.4 centered on the canvas.
    private var canvas: CGSize { CGSize(width: 400, height: 260) }

    func testRectangleAnnotationChangesPixelsOnlyInsideItsBox() {
        let s = plainSettings
        let screen = plainScreen
        let spec = AnnotationSpec(id: "r", kind: "rectangle", start: 0, end: 1,
                                  rect: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3),
                                  color: RGBAColor(r: 1, g: 1, b: 1, a: 1), strokeWidth: 0.02,
                                  fillOpacity: 1)
        let plain = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas))
        let annotated = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, annotations: [spec]))

        // Center of the box (a filled white rectangle over a mid-gray screen): must differ.
        let inside = CGRect(x: 185, y: 115, width: 20, height: 20)
        XCTAssertGreaterThan(
            GoldenAssert.meanAbsDiff(region(plain, inside), region(annotated, inside)), 0.02,
            "expected the rectangle to change pixels inside its box")
        // Well outside the box: identical.
        let outside = CGRect(x: 40, y: 30, width: 40, height: 30)
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(region(plain, outside), region(annotated, outside)), 0.001,
            "rectangle sprite must not leak outside its box")
    }

    /// An arrow whose tip sits exactly at the content's top edge (`arrowEnd.y == 0`, a normal
    /// in-range value), pointing straight up. The shaft's round line cap extends strokeWidth/2
    /// further in the line direction than the tip itself — so, uncropped, it would bleed past
    /// the content boundary into the padding above. Must not change any pixel there, mirroring
    /// `privacyBlurLayer`'s `.intersection(contentRect)` clamp. (Rectangle/ellipse sprites are
    /// inset by half their stroke width so their outer edge never exceeds `rect`'s own bounds;
    /// arrows' round caps are the case that actually overshoots.)
    func testAnnotationFlushAgainstContentEdgeDoesNotBleedIntoPadding() {
        let s = plainSettings
        let screen = plainScreen
        let spec = AnnotationSpec(id: "edge", kind: "arrow", start: 0, end: 1,
                                  rect: CGRect(x: 0.3, y: 0, width: 0.1, height: 0.5),
                                  color: RGBAColor(r: 1, g: 1, b: 1, a: 1), strokeWidth: 0.05,
                                  arrowStart: CGPoint(x: 0.4, y: 0.5), arrowEnd: CGPoint(x: 0.4, y: 0))
        let plain = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas))
        let annotated = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, annotations: [spec]))

        // A strip of the padding just above the content's top edge (content top ≈ canvas y=15.6
        // for this 400×260 canvas / 320×200 screen layout — see the canvas comment above):
        // must be pixel-identical whether or not the annotation is present.
        let paddingAboveContent = CGRect(x: 145, y: 3, width: 40, height: 8)
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(region(plain, paddingAboveContent), region(annotated, paddingAboveContent)),
            0.001, "annotation flush against the content edge must not bleed into the padding")
    }

    func testTextAnnotationChangesPixelsInsideItsRect() {
        let s = plainSettings
        let screen = plainScreen
        let spec = AnnotationSpec(id: "t", kind: "text", start: 0, end: 1,
                                  rect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.3),
                                  color: RGBAColor(r: 1, g: 1, b: 1, a: 1), text: "Hello",
                                  fontSize: 0.15)
        let plain = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas))
        let annotated = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, annotations: [spec]))

        let inside = CGRect(x: 170, y: 105, width: 60, height: 40)
        XCTAssertGreaterThan(
            GoldenAssert.meanAbsDiff(region(plain, inside), region(annotated, inside)), 0.01,
            "expected text to change pixels inside its rect")
        let outside = CGRect(x: 40, y: 30, width: 40, height: 30)
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(region(plain, outside), region(annotated, outside)), 0.001,
            "text sprite must not leak outside its rect")
    }

    func testArrowAnnotationChangesPixelsOnlyAlongItsPathBoundingBox() {
        let s = plainSettings
        let screen = plainScreen
        let spec = AnnotationSpec(id: "a", kind: "arrow", start: 0, end: 1,
                                  rect: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3),
                                  color: RGBAColor(r: 1, g: 1, b: 1, a: 1), strokeWidth: 0.03,
                                  arrowStart: CGPoint(x: 0.3, y: 0.3), arrowEnd: CGPoint(x: 0.6, y: 0.6))
        let plain = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas))
        let annotated = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, annotations: [spec]))

        // Somewhere along the diagonal path bounding box (content-space midpoint of the two
        // endpoints, mapped to canvas pixels): must differ.
        let alongPath = CGRect(x: 205, y: 120, width: 20, height: 20)
        XCTAssertGreaterThan(
            GoldenAssert.meanAbsDiff(region(plain, alongPath), region(annotated, alongPath)), 0.01,
            "expected the arrow to change pixels along its path")
        // Far from the path's bounding box: identical.
        let outside = CGRect(x: 40, y: 30, width: 40, height: 30)
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(region(plain, outside), region(annotated, outside)), 0.001,
            "arrow sprite must not leak outside its path bounding box")
    }

    func testSpotlightHoleUnchangedOutsideDarker() {
        let s = plainSettings
        let screen = plainScreen
        let spec = AnnotationSpec(id: "sp", kind: "spotlight", start: 0, end: 1,
                                  rect: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3),
                                  cornerRadius: 0, dimOpacity: 0.7)
        let plain = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas))
        let spotlit = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas, annotations: [spec]))

        // Deep inside the hole: unchanged vs no-annotation render.
        let insideHole = CGRect(x: 190, y: 120, width: 10, height: 10)
        XCTAssertLessThan(
            GoldenAssert.meanAbsDiff(region(plain, insideHole), region(spotlit, insideHole)), 0.005,
            "pixels inside the spotlight hole must be unchanged")
        // Outside the hole: darker (dimmed).
        let outsideHole = CGRect(x: 40, y: 30, width: 40, height: 30)
        let plainOutside = region(plain, outsideHole)
        let spotlitOutside = region(spotlit, outsideHole)
        XCTAssertGreaterThan(
            GoldenAssert.meanAbsDiff(plainOutside, spotlitOutside), 0.05,
            "pixels outside the spotlight hole must be dimmed")
    }

    func testStackingLaterSpecWinsOnOverlap() {
        let s = plainSettings
        let screen = plainScreen
        let overlap = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        let red = AnnotationSpec(id: "red", kind: "rectangle", start: 0, end: 1, rect: overlap,
                                 color: RGBAColor(r: 1, g: 0, b: 0, a: 1), fillOpacity: 1)
        let blue = AnnotationSpec(id: "blue", kind: "rectangle", start: 0, end: 1, rect: overlap,
                                  color: RGBAColor(r: 0, g: 0, b: 1, a: 1), fillOpacity: 1)

        let redFirst = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas,
            annotations: [red, blue])) // blue drawn last → should win
        let blueFirst = GoldenAssert.cgImage(Compositor().render(
            RenderInputs(screen: screen), settings: s, canvasSize: canvas,
            annotations: [blue, red])) // red drawn last → should win

        let probe = CGRect(x: 195, y: 125, width: 8, height: 8)
        func avgColor(_ img: CGImage, _ r: CGRect) -> (r: Double, g: Double, b: Double) {
            let region = img.cropping(to: r)!
            var data = [UInt8](repeating: 0, count: region.width * region.height * 4)
            let ctx = CGContext(data: &data, width: region.width, height: region.height,
                                bitsPerComponent: 8, bytesPerRow: region.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
            var (r, g, b) = (0.0, 0.0, 0.0)
            let n = region.width * region.height
            for i in 0..<n {
                r += Double(data[i * 4]); g += Double(data[i * 4 + 1]); b += Double(data[i * 4 + 2])
            }
            return (r / Double(n) / 255, g / Double(n) / 255, b / Double(n) / 255)
        }

        let redFirstColor = avgColor(redFirst, probe)
        XCTAssertGreaterThan(redFirstColor.b, 0.6)
        XCTAssertLessThan(redFirstColor.r, 0.3)

        let blueFirstColor = avgColor(blueFirst, probe)
        XCTAssertGreaterThan(blueFirstColor.r, 0.6)
        XCTAssertLessThan(blueFirstColor.b, 0.3)
    }

    // MARK: builder integration

    func testBuilderDropsAnnotationInsideCutAndRemapsStraddling() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1),
                                                     seconds: 4)
        var settings = RenderSettings.default
        settings.cuts = [CutRange(start: 1, end: 2)]
        settings.annotations = [
            AnnotationSpec(id: "dropped", kind: "rectangle", start: 1.2, end: 1.8,
                          rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            AnnotationSpec(id: "straddling", kind: "rectangle", start: 0.5, end: 1.5,
                          rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
        ]

        let built = try await ProjectCompositionBuilder.build(
            timeline: MediaTimeline(screen: .init(url: screenURL, startOffset: 0),
                                    webcam: nil, audio: []),
            settings: settings, canvasSize: CGSize(width: 320, height: 240),
            backgroundImage: nil, retimeForExport: true)

        let instruction = try XCTUnwrap(
            built.videoComposition.instructions.first as? CharmInstruction)
        XCTAssertEqual(instruction.annotations.count, 1,
                       "the fully-cut annotation must be dropped")
        let remapped = try XCTUnwrap(instruction.annotations.first)
        XCTAssertEqual(remapped.id, "straddling")
        XCTAssertEqual(remapped.start, 0.5, accuracy: 0.01)
        XCTAssertEqual(remapped.end, 1.0, accuracy: 0.01) // 1.5, collapsed 0.5s into the cut
    }
}
