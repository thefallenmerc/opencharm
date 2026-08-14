import CoreImage
import CoreImage.CIFilterBuiltins

public struct RenderInputs {
    public var screen: CIImage
    public var webcam: CIImage?
    /// Pre-resolved by the caller when settings.background is .image (Compositor stays file-free).
    public var backgroundImage: CIImage?
    public init(screen: CIImage, webcam: CIImage? = nil, backgroundImage: CIImage? = nil) {
        (self.screen, self.webcam, self.backgroundImage) = (screen, webcam, backgroundImage)
    }
}

public final class Compositor {
    public init() {}

    // Squircle masks are rasterized once per (size, exponent) and reused across frames.
    // `render` can be called from AVFoundation's concurrent request queue → lock the cache.
    // Internal (not private) so Compositor+Annotations.swift's sprite rasterizers share it.
    var maskCache: [String: CIImage] = [:]
    let maskLock = NSLock()

    public func render(_ inputs: RenderInputs, settings: RenderSettings,
                       canvasSize: CGSize, zoom: ZoomState = .identity,
                       cursor: CursorFrame? = nil, blurBoxes: [BlurBoxSpec] = [],
                       annotations: [AnnotationSpec] = []) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        var layout = CanvasLayout.compute(
            canvasSize: canvasSize,
            screenAspect: inputs.screen.extent.width / inputs.screen.extent.height,
            settings: settings)

        // Stage: everything that magnifies together — background, padding, shadow, screen
        // content, and the synthetic cursor. The zoom then scales this WHOLE stage (Screen
        // Charm behavior), so the padding and background glide with the content instead of
        // the video zooming alone inside a static frame.
        var stage = backgroundLayer(settings.background, image: inputs.backgroundImage,
                                    canvasRect: canvasRect)
        if let blur = settings.backgroundBlur, blur > 0.001 {
            let sigma = blur * 0.04 * min(canvasSize.width, canvasSize.height)
            stage = stage.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: canvasRect)
        }
        if settings.shadow.opacity > 0 {
            stage = shadow(for: layout.contentRect, radius: layout.cornerRadius,
                           opacity: settings.shadow.opacity,
                           blurSigma: layout.shadowBlurSigma,
                           offsetY: layout.shadowOffsetY)
                .composited(over: stage)
        }
        stage = place(inputs.screen, in: layout.contentRect,
                      cornerRadius: layout.cornerRadius, over: stage)
        // Privacy blurs sit on the content, before the cursor (which stays sharp above them)
        // and before the zoom (so a magnified region keeps its mask glued to the content).
        if !blurBoxes.isEmpty {
            stage = privacyBlurLayer(stage, boxes: blurBoxes, contentRect: layout.contentRect)
        }
        // Annotations sit on the content too — content-anchored, pre-zoom, above blurs, below
        // the cursor (which stays sharp above everything).
        if !annotations.isEmpty {
            stage = annotationLayers(annotations, contentRect: layout.contentRect, over: stage)
        }
        if let cursor {
            stage = drawCursor(cursor, contentRect: layout.contentRect,
                               canvasSize: canvasSize, over: stage)
        }
        stage = zoomedCanvas(stage, zoom: zoom, contentRect: layout.contentRect,
                             canvasRect: canvasRect)

        // The webcam floats above the zoom (it never magnifies) at a constant size — the
        // default bubble is already small enough to stay unobtrusive over magnified content.
        var result = webcamLayer(inputs.webcam, settings: settings, layout: layout, over: stage)
        // Contract: output is always opaque, regardless of any alpha < 1 in caller-supplied
        // inputs (e.g. a semi-transparent solid/gradient color or a backgroundImage with alpha).
        let opaqueBackdrop = CIImage(color: .black).cropped(to: canvasRect)
        result = result.composited(over: opaqueBackdrop)
        return result.cropped(to: canvasRect)
    }

    /// Scales the composed canvas about the zoom focus (normalized over the screen CONTENT,
    /// top-left origin, mapped into canvas space). The focus point keeps its on-screen position —
    /// the view zooms "in place" toward it — and because scaling up about an interior point only
    /// pushes edges outward, the canvas stays fully covered for any focus: no clamping, no gaps.
    func zoomedCanvas(_ image: CIImage, zoom: ZoomState, contentRect: CGRect,
                      canvasRect: CGRect) -> CIImage {
        guard zoom.scale > 1.0001 else { return image }
        let s = CGFloat(zoom.scale)
        let fx = contentRect.minX + CGFloat(zoom.focus.x) * contentRect.width
        let fy = contentRect.maxY - CGFloat(zoom.focus.y) * contentRect.height // focus top-left; y-up
        let transform = CGAffineTransform(translationX: fx, y: fy)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -fx, y: -fy)
        return image.transformed(by: transform).cropped(to: canvasRect)
    }

    /// Draws the synthetic pointer at the cursor's content location, pre-zoom — the canvas zoom
    /// magnifies it with the content, so it grows in step and never detaches. The image's top-left
    /// corner is the pointer tip. A soft drop shadow sits under it for depth against any background.
    func drawCursor(_ cursor: CursorFrame, contentRect: CGRect,
                    canvasSize: CGSize, over bg: CIImage) -> CIImage {
        let px = contentRect.minX + cursor.point.x * contentRect.width
        let py = contentRect.minY + (1 - cursor.point.y) * contentRect.height // y-up
        let h = CGFloat(cursor.sizeFraction) * canvasSize.height
        let img = cursor.image
        guard img.extent.height > 0, h > 0 else { return bg }
        let s = h / img.extent.height
        let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: px - scaled.extent.minX, y: py - scaled.extent.maxY))
        // Drop shadow: the pointer's silhouette, offset down-right and blurred.
        let silhouette = positioned.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35),
        ])
        let dropShadow = silhouette
            .transformed(by: CGAffineTransform(translationX: h * 0.05, y: -h * 0.06))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: h * 0.05)
            .cropped(to: positioned.extent.insetBy(dx: -h, dy: -h))
        return positioned.composited(over: dropShadow.composited(over: bg))
    }

    // MARK: layers

    private func backgroundLayer(_ background: Background, image: CIImage?,
                                 canvasRect: CGRect) -> CIImage {
        switch background {
        case .solid(let c):
            return CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a))
                .cropped(to: canvasRect)
        case .linearGradient(let start, let end, let angleDegrees):
            let angle = angleDegrees * .pi / 180
            let dir = CGVector(dx: cos(angle), dy: sin(angle))
            let half = CGPoint(x: canvasRect.midX, y: canvasRect.midY)
            let len = (abs(dir.dx) * canvasRect.width + abs(dir.dy) * canvasRect.height) / 2
            let f = CIFilter.linearGradient()
            f.point0 = CGPoint(x: half.x - dir.dx * len, y: half.y - dir.dy * len)
            f.point1 = CGPoint(x: half.x + dir.dx * len, y: half.y + dir.dy * len)
            f.color0 = CIColor(red: start.r, green: start.g, blue: start.b, alpha: start.a)
            f.color1 = CIColor(red: end.r, green: end.g, blue: end.b, alpha: end.a)
            return f.outputImage!.cropped(to: canvasRect)
        case .image:
            guard let image else {
                return CIImage(color: .black).cropped(to: canvasRect) // caller forgot to resolve
            }
            // Scale to fill, center-crop.
            let scale = max(canvasRect.width / image.extent.width,
                            canvasRect.height / image.extent.height)
            let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
            let dx = (scaled.extent.width - canvasRect.width) / 2 - scaled.extent.minX
            let dy = (scaled.extent.height - canvasRect.height) / 2 - scaled.extent.minY
            return scaled.transformed(by: .init(translationX: -dx, y: -dy))
                .cropped(to: canvasRect)
        }
    }

    /// Blurs each normalized content-space region (0…1, top-left origin) of the staged canvas
    /// beyond legibility. The blurred patch is clipped to a rounded rect via source-in
    /// compositing — real transparency outside the shape, so no out-of-extent sampling can
    /// smear it (see the webcam shadow fix for the failure mode this avoids).
    func privacyBlurLayer(_ image: CIImage, boxes: [BlurBoxSpec], contentRect: CGRect) -> CIImage {
        var out = image
        for box in boxes {
            let r = box.rect
            let px = CGRect(
                x: contentRect.minX + r.minX * contentRect.width,
                y: contentRect.minY + (1 - r.minY - r.height) * contentRect.height, // y-up
                width: r.width * contentRect.width,
                height: r.height * contentRect.height)
                .intersection(contentRect)
            guard px.width > 1, px.height > 1 else { continue }
            // Strong enough that a password-sized box is unreadable at any export size.
            // `intensity` (nil/0.5 = legacy) scales the auto sigma linearly about its midpoint.
            let auto = min(60, max(8, min(px.width, px.height) * 0.35))
            let sigma = min(100, max(2, auto * ((box.intensity ?? 0.5) / 0.5)))
            let blurred = out.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: px)
            let radius = min(px.width, px.height) * (box.cornerRadius ?? 0.15)
            let shape = roundedRectMask(rect: px, radius: radius)
            let clipped = blurred.applyingFilter("CISourceInCompositing",
                                                 parameters: [kCIInputBackgroundImageKey: shape])
            out = clipped.composited(over: out)
        }
        return out
    }

    func roundedRectMask(rect: CGRect, radius: CGFloat) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(radius)
        f.color = .white
        return f.outputImage!
    }

    private func shadow(for rect: CGRect, radius: CGFloat, opacity: Double,
                        blurSigma: CGFloat, offsetY: CGFloat) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(radius)
        f.color = CIColor(red: 0, green: 0, blue: 0, alpha: opacity)
        return f.outputImage!
            .applyingGaussianBlur(sigma: blurSigma)
            .transformed(by: .init(translationX: 0, y: -offsetY)) // y-up: shadow falls downward
    }

    func place(_ image: CIImage, in rect: CGRect, cornerRadius: CGFloat,
               over background: CIImage) -> CIImage {
        let sx = rect.width / image.extent.width
        let sy = rect.height / image.extent.height
        let placed = image
            .transformed(by: .init(scaleX: sx, y: sy))
            .transformed(by: .init(translationX: rect.minX - image.extent.minX * sx,
                                   y: rect.minY - image.extent.minY * sy))
        let blend = CIFilter.blendWithMask()
        blend.inputImage = placed
        blend.backgroundImage = background
        blend.maskImage = roundedRectMask(rect: rect, radius: cornerRadius)
        return blend.outputImage!
    }

    func webcamLayer(_ webcam: CIImage?, settings: RenderSettings,
                     layout: CanvasLayout, over background: CIImage) -> CIImage {
        guard settings.webcam.visible, let webcam else { return background }
        // Center-crop to square; contentZoom > 1 tightens the crop for a closer face framing.
        let side = min(webcam.extent.width, webcam.extent.height)
            / max(1, settings.webcam.contentZoom ?? 1)
        let crop = CGRect(x: webcam.extent.midX - side / 2,
                          y: webcam.extent.midY - side / 2, width: side, height: side)
        let square = webcam.cropped(to: crop)
        var result = background
        let rect = layout.webcamRect
        // The mask bitmap carries a transparent border wider than the shadow's reach. The
        // squircle touches its bounding box at each side's midpoint, so a mask that stops
        // exactly at `rect` puts opaque pixels on its own extent edge — and anything that
        // samples past the extent (the shadow blur, blendWithMask on the GPU) then smears
        // those edge pixels into bars beside the bubble with a hard cutoff. Real transparent
        // pixels beyond the silhouette make out-of-extent clamping harmless.
        let sigma = max(3, rect.width * 0.045)
        let shadowOffset = rect.width * 0.03
        let pad = (4 * sigma + shadowOffset).rounded(.up)
        let mask = squircleMask(rect: rect, roundness: settings.webcam.roundness, padding: pad)
        // Elegant drop shadow under the bubble: the squircle's own silhouette (so the shape
        // always matches, circle or squircle), softly blurred with a slight downward offset.
        if settings.shadow.opacity > 0 {
            let silhouette = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: settings.shadow.opacity * 0.55),
            ])
            let dropShadow = silhouette
                .transformed(by: .init(translationX: 0, y: -shadowOffset)) // y-up: downward
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: rect.insetBy(dx: -pad, dy: -pad))
            result = dropShadow.composited(over: result)
        }
        // Squircle bubble: continuous icon-like corners (superellipse), not a plain rounded rect.
        let sx = rect.width / square.extent.width
        let sy = rect.height / square.extent.height
        let placed = square
            .transformed(by: .init(scaleX: sx, y: sy))
            .transformed(by: .init(translationX: rect.minX - square.extent.minX * sx,
                                   y: rect.minY - square.extent.minY * sy))
        let blend = CIFilter.blendWithMask()
        blend.inputImage = placed
        blend.backgroundImage = result
        blend.maskImage = mask
        return blend.outputImage!
    }

    /// White superellipse (|x|ⁿ + |y|ⁿ = 1) on transparent, filling `rect`. The exponent maps
    /// from `roundness` so 1 stays a circle/ellipse (n = 2) and lower values tighten toward a
    /// square with continuous, icon-like corners (e.g. 0.65 → n ≈ 3.1).
    func squircleMask(rect: CGRect, roundness: Double, padding: CGFloat = 0) -> CIImage {
        let n = 2.0 / min(max(roundness, 0.05), 1)
        let w = max(Int(rect.width.rounded()), 2)
        let h = max(Int(rect.height.rounded()), 2)
        let p = max(0, Int(padding.rounded(.up)))
        let key = "\(w)x\(h):\(Int(n * 100)):\(p)"
        maskLock.lock()
        defer { maskLock.unlock() }
        let base: CIImage
        if let hit = maskCache[key] {
            base = hit
        } else {
            guard let ctx = CGContext(
                data: nil, width: w + 2 * p, height: h + 2 * p, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
            let a = Double(w) / 2, b = Double(h) / 2
            let path = CGMutablePath()
            let steps = 256
            for i in 0...steps {
                let t = Double(i) / Double(steps) * 2 * .pi
                let c = cos(t), s = sin(t)
                let x = Double(p) + a + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
                let y = Double(p) + b + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillPath()
            guard let cg = ctx.makeImage() else { return .empty() }
            base = CIImage(cgImage: cg)
            maskCache[key] = base
        }
        return base.transformed(by: .init(translationX: rect.minX - CGFloat(p),
                                          y: rect.minY - CGFloat(p)))
    }
}
