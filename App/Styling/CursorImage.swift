import AppKit
import CoreImage

/// Renders a crisp macOS-style pointer arrow (black fill + white outline) as a `CIImage`, oriented so
/// its tip is at the image's top-left corner (matching how the compositor positions it at the pointer
/// location). Drawn as vectors at high resolution so it stays sharp when scaled up.
enum CursorImage {
    static func make(pixelScale: CGFloat = 8) -> CIImage {
        // Arrow polygon in a y-down box, tip at (0,0).
        let pts: [CGPoint] = [(0, 0), (0, 18), (5, 13), (8, 20), (11, 19), (7, 12), (13, 12)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        let boxW: CGFloat = 13, boxH: CGFloat = 20, pad: CGFloat = 1.5
        let w = Int((boxW + 2 * pad) * pixelScale), h = Int((boxH + 2 * pad) * pixelScale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }

        ctx.scaleBy(x: pixelScale, y: pixelScale)
        ctx.translateBy(x: pad, y: pad)
        // The context is y-up; flip our y-down points so the tip lands near the top-left.
        let path = CGMutablePath()
        path.addLines(between: pts.map { CGPoint(x: $0.x, y: boxH - $0.y) })
        path.closeSubpath()
        ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2.5); ctx.strokePath()
        ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()

        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }

    /// Pointing-hand pointer (links/buttons), matching the arrow's black-fill/white-outline look.
    /// Rendered from the SF Symbol at high resolution; the white outline is the symbol's alpha
    /// dilated and colored, composited underneath. Fingertip lands near the top-left corner,
    /// matching how the compositor anchors the image at the pointer tip.
    static func pointingHand(pixelScale: CGFloat = 8) -> CIImage {
        let size = NSSize(width: 22 * pixelScale, height: 22 * pixelScale)
        let config = NSImage.SymbolConfiguration(pointSize: 20 * pixelScale, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "hand.point.up.left.fill",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return make(pixelScale: pixelScale) }
        let bitmap = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            symbol.draw(in: rect)
            return true
        }
        guard let cg = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return make(pixelScale: pixelScale)
        }
        let base = CIImage(cgImage: cg)
        let outline = base
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .applyingFilter("CIMorphologyMaximum",
                            parameters: [kCIInputRadiusKey: 1.2 * pixelScale])
            .cropped(to: base.extent)
        return base.composited(over: outline)
    }
}
