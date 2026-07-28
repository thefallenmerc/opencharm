import CoreGraphics

/// Deterministic geometry for one composited frame. All rects in Core Image space (y-up).
public struct CanvasLayout: Equatable, Sendable {
    public var contentRect: CGRect
    public var cornerRadius: CGFloat
    public var webcamRect: CGRect
    public var webcamCornerRadius: CGFloat
    public var shadowBlurSigma: CGFloat
    public var shadowOffsetY: CGFloat

    public static func compute(canvasSize: CGSize, screenAspect: CGFloat,
                               settings: RenderSettings) -> CanvasLayout {
        let minDim = min(canvasSize.width, canvasSize.height)
        let padding = CGFloat(settings.paddingFraction) * minDim
        let avail = CGSize(width: canvasSize.width - 2 * padding,
                           height: canvasSize.height - 2 * padding)
        // Fit screenAspect inside avail.
        var content = CGSize(width: avail.width, height: avail.width / screenAspect)
        if content.height > avail.height {
            content = CGSize(width: avail.height * screenAspect, height: avail.height)
        }
        let contentRect = CGRect(
            x: (canvasSize.width - content.width) / 2,
            y: (canvasSize.height - content.height) / 2,
            width: content.width, height: content.height)
        let cornerRadius = CGFloat(settings.cornerRadiusFraction) * min(content.width, content.height)

        let side = CGFloat(settings.webcam.size) * minDim
        var origin = CGPoint(
            x: CGFloat(settings.webcam.center.x) * canvasSize.width - side / 2,
            y: (1 - CGFloat(settings.webcam.center.y)) * canvasSize.height - side / 2)
        origin.x = max(0, min(origin.x, canvasSize.width - side))
        origin.y = max(0, min(origin.y, canvasSize.height - side))

        return CanvasLayout(
            contentRect: contentRect,
            cornerRadius: cornerRadius,
            webcamRect: CGRect(origin: origin, size: CGSize(width: side, height: side)),
            webcamCornerRadius: CGFloat(settings.webcam.roundness) * side / 2,
            shadowBlurSigma: CGFloat(settings.shadow.radius) * minDim,
            shadowOffsetY: CGFloat(settings.shadow.offsetY) * minDim)
    }
}
