import AppKit
import CoreImage

/// Renders a crisp macOS-style pointer arrow (black fill + white outline) as a `CIImage`, oriented so
/// its tip is at the image's top-left corner (matching how the compositor positions it at the pointer
/// location). Drawn as vectors at high resolution so it stays sharp when scaled up.
enum CursorImage {
    private static let boxW: CGFloat = 13, boxH: CGFloat = 20, boxPad: CGFloat = 1.5

    /// The arrow polygon, in a y-up box ready to draw into a context scaled/translated by
    /// `arrowContext(pixelScale:)` — flipped from the y-down points the tip is authored in, so
    /// the tip lands near the top-left the way the compositor expects.
    private static func arrowPath() -> CGMutablePath {
        let pts: [CGPoint] = [(0, 0), (0, 18), (5, 13), (8, 20), (11, 19), (7, 12), (13, 12)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        let path = CGMutablePath()
        path.addLines(between: pts.map { CGPoint(x: $0.x, y: boxH - $0.y) })
        path.closeSubpath()
        return path
    }

    private static func arrowContext(pixelScale: CGFloat) -> CGContext? {
        let w = Int((boxW + 2 * boxPad) * pixelScale), h = Int((boxH + 2 * boxPad) * pixelScale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        ctx.translateBy(x: boxPad, y: boxPad)
        ctx.setLineJoin(.round)
        return ctx
    }

    /// - Parameters:
    ///   - fill: the polygon's fill color. Defaults to today's classic look (black).
    ///   - outline: the polygon's stroke color. Defaults to today's classic look (white).
    static func make(pixelScale: CGFloat = 8, fill: CGColor = NSColor.black.cgColor,
                     outline: CGColor = NSColor.white.cgColor) -> CIImage {
        guard let ctx = arrowContext(pixelScale: pixelScale) else { return CIImage.empty() }
        let path = arrowPath()
        ctx.addPath(path); ctx.setStrokeColor(outline); ctx.setLineWidth(2.5); ctx.strokePath()
        ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }

    /// Same polygon as `make`, but filled with `gradient` (clipped to the polygon) instead of a
    /// flat color, with a soft outline around it. `start`/`end` are in the same y-down box
    /// `make`'s tip coordinates use.
    static func makeGradient(pixelScale: CGFloat = 8, gradient: CGGradient,
                             start: CGPoint, end: CGPoint,
                             outline: CGColor = NSColor.white.cgColor) -> CIImage {
        guard let ctx = arrowContext(pixelScale: pixelScale) else { return CIImage.empty() }
        let path = arrowPath()
        ctx.addPath(path); ctx.setStrokeColor(outline); ctx.setLineWidth(2.5); ctx.strokePath()

        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let flippedStart = CGPoint(x: start.x, y: boxH - start.y)
        let flippedEnd = CGPoint(x: end.x, y: boxH - end.y)
        ctx.drawLinearGradient(gradient, start: flippedStart, end: flippedEnd, options: [])
        ctx.restoreGState()

        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }

    /// A translucent radial "halo" ring around the pointer: a soft glow near the outer edge with
    /// a transparent hole in the middle so the content underneath stays visible. Meant to be
    /// anchored by its CENTER (hotspot (0.5, 0.5)), not a tip.
    static func halo(pixelScale: CGFloat = 8, diameter: CGFloat = 22, holeFraction: CGFloat = 0.35)
        -> CIImage {
        let pad: CGFloat = 3 // transparent border so the glow doesn't get clipped
        let side = Int((diameter + 2 * pad) * pixelScale)
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        let center = CGPoint(x: diameter / 2 + pad, y: diameter / 2 + pad)
        let radius = diameter / 2
        let colors = [
            CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 1, 1, 0])!,
            CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 1, 1, 0.85])!,
            CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 1, 1, 0])!,
        ]
        let peakLocation: CGFloat = holeFraction + (1 - holeFraction) * 0.35
        let locations: [CGFloat] = [0, peakLocation, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
            locations: locations) else {
            return CIImage.empty()
        }
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: radius * holeFraction,
                               endCenter: center, endRadius: radius, options: [])
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }

    /// An emoji glyph rasterized at high resolution, matching `pointingHand`'s approach. The
    /// caller supplies where the meaningful "tip" of the glyph sits via `hotspot` on `CursorArt`
    /// — this just renders the bitmap.
    static func emoji(_ glyph: String, pixelScale: CGFloat = 8, pointSize: CGFloat = 20) -> CIImage {
        let size = NSSize(width: 22 * pixelScale, height: 22 * pixelScale)
        let font = NSFont.systemFont(ofSize: pointSize * pixelScale)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let str = NSAttributedString(string: glyph, attributes: attrs)
        let strSize = str.size()
        let bitmap = NSImage(size: size, flipped: false) { rect in
            let origin = CGPoint(x: (rect.width - strSize.width) / 2,
                                 y: (rect.height - strSize.height) / 2)
            str.draw(at: origin)
            return true
        }
        guard let cg = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return CIImage.empty()
        }
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
