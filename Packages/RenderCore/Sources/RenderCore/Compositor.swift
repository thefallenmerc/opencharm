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
                       canvasSize: CGSize) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let layout = CanvasLayout.compute(
            canvasSize: canvasSize,
            screenAspect: inputs.screen.extent.width / inputs.screen.extent.height,
            settings: settings)

        var result = backgroundLayer(settings.background, image: inputs.backgroundImage,
                                     canvasRect: canvasRect)
        if settings.shadow.opacity > 0 {
            result = shadow(for: layout.contentRect, radius: layout.cornerRadius,
                            opacity: settings.shadow.opacity,
                            blurSigma: layout.shadowBlurSigma,
                            offsetY: layout.shadowOffsetY)
                .composited(over: result)
        }
        result = place(inputs.screen, in: layout.contentRect,
                       cornerRadius: layout.cornerRadius, over: result)
        result = webcamLayer(inputs.webcam, settings: settings, layout: layout, over: result)
        // Contract: output is always opaque, regardless of any alpha < 1 in caller-supplied
        // inputs (e.g. a semi-transparent solid/gradient color or a backgroundImage with alpha).
        let opaqueBackdrop = CIImage(color: .black).cropped(to: canvasRect)
        result = result.composited(over: opaqueBackdrop)
        return result.cropped(to: canvasRect)
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

    /// Webcam bubble — implemented in Task 5. Until then, pass-through.
    func webcamLayer(_ webcam: CIImage?, settings: RenderSettings,
                     layout: CanvasLayout, over background: CIImage) -> CIImage {
        background
    }
}
