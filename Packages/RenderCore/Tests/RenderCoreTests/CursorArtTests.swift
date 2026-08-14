import AppKit
import CoreImage
import XCTest
@testable import RenderCore

/// Hotspot-aware anchoring for the synthetic pointer (`CursorFrame.hotspot` / `CursorArt`).
/// These probe actual composited pixels rather than pixel goldens: a plain, hard-edged, fully
/// opaque solid-color square as the "art" removes any anti-aliasing ambiguity at its edges, so a
/// probe well inside or outside its expected footprint is unambiguous.
final class CursorArtTests: XCTestCase {
    private func screen() -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
    }

    /// A hard-edged, fully opaque 40×40 red square — no stroke, no anti-aliased edge, so any
    /// pixel inside its bounds reads as pure red and any pixel outside does not.
    private func redSquare() -> CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
    }

    private func settings() -> RenderSettings {
        var s = RenderSettings.default
        s.webcam.visible = false
        s.background = .solid(RGBAColor(r: 0, g: 0, b: 1)) // blue: unambiguously not-red
        s.shadow.opacity = 0 // isolate the art itself from its drop shadow
        return s
    }

    /// The canvas-space pointer anchor (CoreImage y-up coordinates) that `Compositor.render`
    /// computes internally for `point` — reproduced here from the already-tested `CanvasLayout`,
    /// independent of the hotspot math under test.
    private func pointerAnchor(point: CGPoint, canvas: CGSize, settings: RenderSettings) -> CGPoint {
        let layout = CanvasLayout.compute(canvasSize: canvas, screenAspect: 320.0 / 200.0,
                                          settings: settings)
        let px = layout.contentRect.minX + point.x * layout.contentRect.width
        let py = layout.contentRect.minY + (1 - point.y) * layout.contentRect.height
        return CGPoint(x: px, y: py)
    }

    /// Samples the rendered canvas at a CoreImage-space (y-up) point and reports whether it's
    /// (approximately) the opaque red test square vs. anything else (background/blue/shadow).
    private func isRed(_ image: CIImage, at ciPoint: CGPoint) -> Bool {
        let cg = GoldenAssert.cgImage(image)
        let rep = NSBitmapImageRep(cgImage: cg)
        let extent = image.extent
        let col = Int((ciPoint.x - extent.minX).rounded(.down))
        let row = Int((extent.maxY - ciPoint.y).rounded(.down))
        guard col >= 0, col < rep.pixelsWide, row >= 0, row < rep.pixelsHigh,
              let color = rep.colorAt(x: col, y: row) else { return false }
        return color.redComponent > 0.7 && color.greenComponent < 0.3 && color.blueComponent < 0.3
    }

    // MARK: - 1. Hotspot .zero: art's top-left corner lands exactly at the pointer point.

    func testHotspotZeroAnchorsArtsTopLeftAtThePointerPoint() {
        let c = Compositor()
        let canvas = CGSize(width: 400, height: 260)
        let s = settings()
        let point = CGPoint(x: 0.5, y: 0.5)
        let anchor = pointerAnchor(point: point, canvas: canvas, settings: s)

        let frame = CursorFrame(image: redSquare(), point: point, sizeFraction: 0.3,
                                hotspot: .zero)
        let out = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                           cursor: frame)

        // Deep inside the square hanging down-right from the anchor (top-left-anchored art
        // occupies x ∈ [anchor.x, anchor.x+78], y ∈ [anchor.y-78, anchor.y] in CI's y-up space).
        XCTAssertTrue(isRed(out, at: CGPoint(x: anchor.x + 65, y: anchor.y - 65)))
        // Nothing above-and-left of the anchor — the tip, not the center, sits at the pointer.
        XCTAssertFalse(isRed(out, at: CGPoint(x: anchor.x - 20, y: anchor.y + 20)))
    }

    // MARK: - 2. Hotspot (0.5, 0.5): art is centered on the pointer point.

    func testCenteredHotspotAnchorsArtsCenterAtThePointerPoint() {
        let c = Compositor()
        let canvas = CGSize(width: 400, height: 260)
        let s = settings()
        let point = CGPoint(x: 0.5, y: 0.5)
        let anchor = pointerAnchor(point: point, canvas: canvas, settings: s)

        let frame = CursorFrame(image: redSquare(), point: point, sizeFraction: 0.3,
                                hotspot: CGPoint(x: 0.5, y: 0.5))
        let out = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                           cursor: frame)

        // The pointer point itself is now inside the square (its center).
        XCTAssertTrue(isRed(out, at: anchor))
        // The corner that WAS covered under hotspot .zero is empty now that the art recentered.
        XCTAssertFalse(isRed(out, at: CGPoint(x: anchor.x + 65, y: anchor.y - 65)))
    }

    // MARK: - 3. Click pulse + centered hotspot: shrinking keeps the center anchored.

    func testCenteredHotspotStaysAnchoredThroughTheClickPulse() {
        let c = Compositor()
        let canvas = CGSize(width: 400, height: 260)
        let s = settings()
        let point = CGPoint(x: 0.5, y: 0.5)
        let anchor = pointerAnchor(point: point, canvas: canvas, settings: s)

        // Two pulse phases: at rest (scale 1) and at the bottom of a click's shrink
        // (`CursorPulse.depth`). Centered art must stay centered on the pointer at both sizes.
        for scale in [1.0, CursorPulse.depth] {
            let frame = CursorFrame(image: redSquare(), point: point,
                                    sizeFraction: 0.3 * scale, hotspot: CGPoint(x: 0.5, y: 0.5))
            let out = c.render(RenderInputs(screen: screen()), settings: s, canvasSize: canvas,
                               cursor: frame)
            XCTAssertTrue(isRed(out, at: anchor), "center should stay anchored at pulse scale \(scale)")
        }
    }

    // Legacy decode (absent `cursorStyle` → nil → classic) is covered alongside the other
    // additive-optional `RenderSettings` fields in `RenderSettingsTests.testDecodesLegacySettingsWithoutZoomsOrTrim`.
}
