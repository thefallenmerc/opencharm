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
}
