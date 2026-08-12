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

    public func render(_ inputs: RenderInputs, settings: RenderSettings,
                       canvasSize: CGSize, zoom: ZoomState = .identity,
                       cursor: CursorFrame? = nil) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        // Auto-zoom is a crop of the screen layer only; the crop preserves aspect, so the layout
        // (contentRect, corner radius, webcam, shadow) is unaffected.
        let screen = zoomedScreen(inputs.screen, zoom: zoom)
        var layout = CanvasLayout.compute(
            canvasSize: canvasSize,
            screenAspect: screen.extent.width / screen.extent.height,
            settings: settings)
        // Shrink the webcam bubble slightly while zoomed in, in step with the zoom envelope, so it
        // stays unobtrusive over the magnified content (matches the reference).
        if zoom.progress > 0 {
            let f = CGFloat(1 - 0.5 * min(max(zoom.progress, 0), 1)) // half size at full zoom
            layout.webcamRect = shrink(layout.webcamRect, by: f)
            layout.webcamCornerRadius *= f
        }

        var result = backgroundLayer(settings.background, image: inputs.backgroundImage,
                                     canvasRect: canvasRect)
        if let blur = settings.backgroundBlur, blur > 0.001 {
            let sigma = blur * 0.04 * min(canvasSize.width, canvasSize.height)
            result = result.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: canvasRect)
        }
        if settings.shadow.opacity > 0 {
            result = shadow(for: layout.contentRect, radius: layout.cornerRadius,
                            opacity: settings.shadow.opacity,
                            blurSigma: layout.shadowBlurSigma,
                            offsetY: layout.shadowOffsetY)
                .composited(over: result)
        }
        result = place(screen, in: layout.contentRect,
                       cornerRadius: layout.cornerRadius, over: result)
        if let cursor {
            result = drawCursor(cursor, zoom: zoom, contentRect: layout.contentRect,
                                canvasSize: canvasSize, over: result)
        }
        result = webcamLayer(inputs.webcam, settings: settings, layout: layout, over: result)
        // Contract: output is always opaque, regardless of any alpha < 1 in caller-supplied
        // inputs (e.g. a semi-transparent solid/gradient color or a backgroundImage with alpha).
        let opaqueBackdrop = CIImage(color: .black).cropped(to: canvasRect)
        result = result.composited(over: opaqueBackdrop)
        return result.cropped(to: canvasRect)
    }

    /// Crops the screen to a `1/scale` window centered on `zoom.focus` (normalized, top-left),
    /// clamped inside the frame so the zoomed content always fully covers its rect (no empty
    /// edges). `scale == 1` returns the image unchanged.
    func zoomedScreen(_ screen: CIImage, zoom: ZoomState) -> CIImage {
        guard zoom.scale > 1.0001 else { return screen }
        let e = screen.extent
        let cw = e.width / CGFloat(zoom.scale)
        let ch = e.height / CGFloat(zoom.scale)
        let cx = e.minX + CGFloat(zoom.focus.x) * e.width
        let cy = e.minY + (1 - CGFloat(zoom.focus.y)) * e.height // focus is top-left; CIImage is y-up
        var minX = cx - cw / 2
        var minY = cy - ch / 2
        minX = min(max(minX, e.minX), e.maxX - cw)
        minY = min(max(minY, e.minY), e.maxY - ch)
        return screen.cropped(to: CGRect(x: minX, y: minY, width: cw, height: ch))
    }

    /// Draws the synthetic pointer at the cursor's location — mapped through the same zoom crop as
    /// the screen, so it tracks the visible content, grows with the zoom, and hides when the pointer
    /// is outside the zoomed viewport. The image's top-left corner is placed at the pointer tip.
    func drawCursor(_ cursor: CursorFrame, zoom: ZoomState, contentRect: CGRect,
                    canvasSize: CGSize, over bg: CIImage) -> CIImage {
        let scale = CGFloat(max(zoom.scale, 1))
        let half = 0.5 / scale
        let nx = cursor.point.x, ny = cursor.point.y                  // pointer, normalized top-left
        // crop is centred on the (clamped) zoom focus — same as `zoomedScreen`.
        let cx = min(max(zoom.focus.x, half), 1 - half)
        let cy = min(max(zoom.focus.y, half), 1 - half)
        let u = (nx - (cx - half)) / (2 * half)                       // pointer position within the crop
        let v = (ny - (cy - half)) / (2 * half)
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return bg }       // outside the zoomed viewport
        let px = contentRect.minX + u * contentRect.width
        let py = contentRect.minY + (1 - v) * contentRect.height      // y-up
        let h = CGFloat(cursor.sizeFraction) * canvasSize.height * scale
        let img = cursor.image
        guard img.extent.height > 0 else { return bg }
        let s = h / img.extent.height
        let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: px - scaled.extent.minX, y: py - scaled.extent.maxY))
        return positioned.composited(over: bg)
    }

    /// Scales a rect about its center by `f` (used to shrink the webcam bubble during zoom).
    private func shrink(_ rect: CGRect, by f: CGFloat) -> CGRect {
        let w = rect.width * f, h = rect.height * f
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
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
        if settings.shadow.opacity > 0 {
            result = shadow(for: layout.webcamRect, radius: layout.webcamCornerRadius,
                            opacity: settings.shadow.opacity * 0.6,
                            blurSigma: layout.shadowBlurSigma * 0.6,
                            offsetY: layout.shadowOffsetY * 0.6)
                .composited(over: result)
        }
        return place(square, in: layout.webcamRect,
                     cornerRadius: layout.webcamCornerRadius, over: result)
    }
}
