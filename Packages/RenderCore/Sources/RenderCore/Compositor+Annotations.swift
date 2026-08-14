import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

/// Draws timeline-scoped annotations (text, rectangle, ellipse, arrow, spotlight) over the
/// staged content. Extension on `Compositor` so sprite rasterization shares the same
/// `maskCache`/`maskLock` as the squircle/blur masks — required for `render` to stay
/// deterministic and safe under AVFoundation's concurrent, out-of-order frame requests.
extension Compositor {
    private static let defaultColor = RGBAColor(r: 1, g: 0.23, b: 0.19, a: 1)
    /// Transparent border every rasterized sprite carries beyond its shape, so GPU compositing
    /// never samples past a hard edge and smears it (the webcam-shadow failure mode this file
    /// follows the discipline of; see Compositor.swift:153-156/226-233).
    private static let spritePadding: CGFloat = 8

    /// Composites every active annotation over `stage`, in array order (later = on top).
    /// Non-spotlight kinds draw their own sprite immediately; spotlights are collected and
    /// applied last as a single dim layer with every active hole punched into it together.
    func annotationLayers(_ specs: [AnnotationSpec], contentRect: CGRect, over stage: CIImage) -> CIImage {
        var out = stage
        var spotlights: [AnnotationSpec] = []
        for spec in specs {
            guard let kind = spec.resolvedKind else { continue }
            switch kind {
            case .spotlight:
                spotlights.append(spec)
            case .text:
                out = textLayer(spec, contentRect: contentRect, over: out)
            case .rectangle:
                out = shapeLayer(spec, contentRect: contentRect, ellipse: false, over: out)
            case .ellipse:
                out = shapeLayer(spec, contentRect: contentRect, ellipse: true, over: out)
            case .arrow:
                out = arrowLayer(spec, contentRect: contentRect, over: out)
            }
        }
        if !spotlights.isEmpty {
            out = spotlightLayer(spotlights, contentRect: contentRect, over: out)
        }
        return out
    }

    // MARK: geometry mapping (same normalized content space as `privacyBlurLayer`)

    private func annotationPixelRect(_ r: CGRect, in contentRect: CGRect) -> CGRect {
        CGRect(x: contentRect.minX + r.minX * contentRect.width,
              y: contentRect.minY + (1 - r.minY - r.height) * contentRect.height, // y-up
              width: r.width * contentRect.width,
              height: r.height * contentRect.height)
    }

    private func annotationPixelPoint(_ p: CGPoint, in contentRect: CGRect) -> CGPoint {
        CGPoint(x: contentRect.minX + p.x * contentRect.width,
               y: contentRect.minY + (1 - p.y) * contentRect.height) // y-up
    }

    private func colorKey(_ c: RGBAColor) -> String {
        "\(Int((c.r * 1000).rounded())),\(Int((c.g * 1000).rounded()))," +
            "\(Int((c.b * 1000).rounded())),\(Int((c.a * 1000).rounded()))"
    }

    // MARK: text

    private func textLayer(_ spec: AnnotationSpec, contentRect: CGRect, over stage: CIImage) -> CIImage {
        guard let text = spec.text, !text.isEmpty else { return stage }
        let px = annotationPixelRect(spec.rect, in: contentRect)
        guard px.width > 1, px.height > 1 else { return stage }
        let color = spec.color ?? Self.defaultColor
        let fontSize = CGFloat((spec.fontSize ?? 0.045) * contentRect.height)
        guard fontSize > 0.5 else { return stage }
        let pad = Self.spritePadding
        let sprite = cachedTextSprite(text: text, fontSize: fontSize, color: color,
                                      width: px.width, height: px.height, pad: pad)
        let positioned = sprite.transformed(by: .init(
            translationX: px.minX - pad, y: px.minY - pad))
        // Clamp to the content bounds, same as `privacyBlurLayer`'s `.intersection(contentRect)`:
        // a rect flush against a content edge must not bleed sprite pixels into the padding.
        return positioned.cropped(to: contentRect).composited(over: stage)
    }

    private func cachedTextSprite(text: String, fontSize: CGFloat, color: RGBAColor,
                                  width: CGFloat, height: CGFloat, pad: CGFloat) -> CIImage {
        let w = max(1, Int(width.rounded()))
        let h = max(1, Int(height.rounded()))
        var hasher = Hasher()
        hasher.combine(text)
        let textHash = hasher.finalize()
        let padI = Int(pad.rounded(.up))
        let key = "text:\(textHash):\(Int(fontSize.rounded())):\(colorKey(color)):\(w)x\(h)"
        maskLock.lock()
        defer { maskLock.unlock() }
        if let hit = maskCache[key] { return hit }
        guard let ctx = CGContext(
            data: nil, width: w + 2 * padI, height: h + 2 * padI, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }

        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName(".AppleSystemUIFont" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // A rect path in this (bottom-left origin, y-up) context lays lines from its top down —
        // exactly "top-left of rect = top-left of text block" once placed at `pad, pad`.
        let path = CGPath(rect: CGRect(x: CGFloat(padI), y: CGFloat(padI), width: CGFloat(w), height: CGFloat(h)),
                          transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)

        guard let cg = ctx.makeImage() else { return .empty() }
        let img = CIImage(cgImage: cg)
        maskCache[key] = img
        return img
    }

    // MARK: rectangle / ellipse

    private func shapeLayer(_ spec: AnnotationSpec, contentRect: CGRect, ellipse: Bool,
                            over stage: CIImage) -> CIImage {
        let px = annotationPixelRect(spec.rect, in: contentRect)
        guard px.width > 1, px.height > 1 else { return stage }
        let color = spec.color ?? Self.defaultColor
        let strokePx = CGFloat((spec.strokeWidth ?? 0.006) * min(contentRect.width, contentRect.height))
        let fillOpacity = spec.fillOpacity ?? 0
        let radiusPx = ellipse ? 0
            : CGFloat(spec.cornerRadius ?? 0.15) * min(px.width, px.height)
        let pad = Self.spritePadding + strokePx / 2
        let sprite = cachedShapeSprite(ellipse: ellipse, width: px.width, height: px.height,
                                       strokePx: strokePx, radiusPx: radiusPx, pad: pad,
                                       color: color, fillOpacity: fillOpacity)
        let positioned = sprite.transformed(by: .init(
            translationX: px.minX - pad, y: px.minY - pad))
        // Clamp to the content bounds, same as `privacyBlurLayer`'s `.intersection(contentRect)`:
        // a rect flush against a content edge must not bleed sprite pixels into the padding.
        return positioned.cropped(to: contentRect).composited(over: stage)
    }

    private func cachedShapeSprite(ellipse: Bool, width: CGFloat, height: CGFloat, strokePx: CGFloat,
                                   radiusPx: CGFloat, pad: CGFloat, color: RGBAColor,
                                   fillOpacity: Double) -> CIImage {
        let w = max(1, Int(width.rounded()))
        let h = max(1, Int(height.rounded()))
        let padI = Int(pad.rounded(.up))
        let strokeRounded = Int(strokePx.rounded())
        let radiusRounded = Int(radiusPx.rounded())
        let key = "\(ellipse ? "ellipse" : "rect"):\(w)x\(h):\(strokeRounded):\(radiusRounded):" +
            "\(colorKey(color)):\(Int((fillOpacity * 1000).rounded()))"
        maskLock.lock()
        defer { maskLock.unlock() }
        if let hit = maskCache[key] { return hit }
        guard let ctx = CGContext(
            data: nil, width: w + 2 * padI, height: h + 2 * padI, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }

        let shapeRect = CGRect(x: CGFloat(padI), y: CGFloat(padI), width: CGFloat(w), height: CGFloat(h))
            .insetBy(dx: strokePx / 2, dy: strokePx / 2)
        let clampedRadius = min(radiusPx, min(shapeRect.width, shapeRect.height) / 2)
        let path: CGPath = ellipse
            ? CGPath(ellipseIn: shapeRect, transform: nil)
            : CGPath(roundedRect: shapeRect, cornerWidth: max(0, clampedRadius),
                    cornerHeight: max(0, clampedRadius), transform: nil)
        ctx.addPath(path)
        if fillOpacity > 0, let fillColor = color.cgColor.copy(alpha: fillOpacity) {
            ctx.setFillColor(fillColor)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(strokePx)
            ctx.drawPath(using: .fillStroke)
        } else {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(strokePx)
            ctx.drawPath(using: .stroke)
        }

        guard let cg = ctx.makeImage() else { return .empty() }
        let img = CIImage(cgImage: cg)
        maskCache[key] = img
        return img
    }

    // MARK: arrow

    private func arrowLayer(_ spec: AnnotationSpec, contentRect: CGRect, over stage: CIImage) -> CIImage {
        let r = spec.rect
        let startNorm = spec.arrowStart ?? CGPoint(x: r.minX, y: r.minY + r.height / 2)
        let endNorm = spec.arrowEnd ?? CGPoint(x: r.maxX, y: r.minY + r.height / 2)
        let p1 = annotationPixelPoint(startNorm, in: contentRect)
        let p2 = annotationPixelPoint(endNorm, in: contentRect)
        let color = spec.color ?? Self.defaultColor
        let strokePx = CGFloat((spec.strokeWidth ?? 0.006) * min(contentRect.width, contentRect.height))
        let headSize = strokePx * 3
        let bbox = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                          width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
        let pad = Self.spritePadding + headSize
        let w = max(1, Int(bbox.width.rounded()))
        let h = max(1, Int(bbox.height.rounded()))
        // Endpoints in the sprite's own local (already-padded) coordinate space.
        let local1 = CGPoint(x: p1.x - bbox.minX + pad, y: p1.y - bbox.minY + pad)
        let local2 = CGPoint(x: p2.x - bbox.minX + pad, y: p2.y - bbox.minY + pad)
        let sprite = cachedArrowSprite(width: w, height: h, pad: pad, p1: local1, p2: local2,
                                       strokePx: strokePx, headSize: headSize, color: color)
        let positioned = sprite.transformed(by: .init(
            translationX: bbox.minX - pad, y: bbox.minY - pad))
        // Clamp to the content bounds, same as `privacyBlurLayer`'s `.intersection(contentRect)`:
        // an arrow whose endpoint sits at a content edge must not bleed sprite pixels into the
        // padding.
        return positioned.cropped(to: contentRect).composited(over: stage)
    }

    private func cachedArrowSprite(width: Int, height: Int, pad: CGFloat, p1: CGPoint, p2: CGPoint,
                                   strokePx: CGFloat, headSize: CGFloat, color: RGBAColor) -> CIImage {
        let padI = Int(pad.rounded(.up))
        let key = "arrow:\(width)x\(height):\(Int(p1.x.rounded())),\(Int(p1.y.rounded())):" +
            "\(Int(p2.x.rounded())),\(Int(p2.y.rounded())):\(Int(strokePx.rounded())):\(colorKey(color))"
        maskLock.lock()
        defer { maskLock.unlock() }
        if let hit = maskCache[key] { return hit }
        guard let ctx = CGContext(
            data: nil, width: width + 2 * padI, height: height + 2 * padI, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }

        var dx = p2.x - p1.x, dy = p2.y - p1.y
        let len = (dx * dx + dy * dy).squareRoot()
        if len > 0.0001 { dx /= len; dy /= len } else { dx = 1; dy = 0 }

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokePx)
        ctx.setLineCap(.round)
        ctx.move(to: p1)
        ctx.addLine(to: p2)
        ctx.strokePath()

        // Filled triangular head at the end, ~3× the stroke width.
        let perp = CGPoint(x: -dy, y: dx)
        let base = CGPoint(x: p2.x - dx * headSize, y: p2.y - dy * headSize)
        let left = CGPoint(x: base.x + perp.x * headSize * 0.5, y: base.y + perp.y * headSize * 0.5)
        let right = CGPoint(x: base.x - perp.x * headSize * 0.5, y: base.y - perp.y * headSize * 0.5)
        ctx.setFillColor(color.cgColor)
        ctx.move(to: p2)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()

        guard let cg = ctx.makeImage() else { return .empty() }
        let img = CIImage(cgImage: cg)
        maskCache[key] = img
        return img
    }

    // MARK: spotlight

    /// One dim backdrop (from the FIRST active spotlight's `dimOpacity`) with every active
    /// spotlight's rounded-rect hole punched into it together, then composited over the stage.
    private func spotlightLayer(_ specs: [AnnotationSpec], contentRect: CGRect, over stage: CIImage) -> CIImage {
        guard let first = specs.first else { return stage }
        let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: first.dimOpacity ?? 0.55))
            .cropped(to: stage.extent)
        var combinedHoles: CIImage?
        for spec in specs {
            let px = annotationPixelRect(spec.rect, in: contentRect).intersection(contentRect)
            guard px.width > 1, px.height > 1 else { continue }
            let radius = min(px.width, px.height) * (spec.cornerRadius ?? 0.15)
            let hole = roundedRectMask(rect: px, radius: radius)
            combinedHoles = combinedHoles.map { hole.composited(over: $0) } ?? hole
        }
        guard let holes = combinedHoles else { return stage }
        let punched = dim.applyingFilter("CISourceOutCompositing",
                                         parameters: [kCIInputBackgroundImageKey: holes])
        return punched.composited(over: stage)
    }
}
