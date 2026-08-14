import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// The 3D-motion (tilt) half of the compositor's content stage. Split out of `Compositor.swift`
/// so the flat path there stays exactly the code it always was — the identity fast path is the
/// contract this whole feature is built around.
///
/// Everything here is a pure function of its arguments: no per-frame state is added to the
/// concurrent render path, and the only shared mutable thing it can reach is the lock-guarded
/// `maskCache` the sprite rasterizers already use.
extension Compositor {
    /// Builds the content card (screen + privacy blurs + non-spotlight annotations + cursor),
    /// warps it through `tilt`, drops its shadow, and composites the result over `background`.
    /// Replaces the flat path's shadow→content→blurs→annotations→cursor run.
    func tiltedContentLayer(_ inputs: RenderInputs, settings: RenderSettings,
                            layout: CanvasLayout, canvasSize: CGSize, tilt: TiltState,
                            blurBoxes: [BlurBoxSpec], annotations: [AnnotationSpec],
                            cursor: CursorFrame?, over background: CIImage) -> CIImage {
        let contentRect = layout.contentRect
        let pad = cardPadding(cursor: cursor, canvasSize: canvasSize)
        let cardRect = contentRect.insetBy(dx: -pad, dy: -pad)

        // 1. The card, over REAL transparency rather than over the stage. A perspective warp
        //    resamples outside its input, and Core Image clamps out-of-extent reads to the edge
        //    pixel — build the card on the opaque stage and that clamping smears the background
        //    into bars along the tilted edges (the webcam-shadow failure mode, `webcamLayer`).
        //    Transparent pixels all around mean the resample interpolates against real zeros.
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: cardRect)
        var card = place(inputs.screen, in: contentRect,
                         cornerRadius: layout.cornerRadius, over: clear)
        // Blurs, annotation sprites and the pointer are all content-anchored, so they belong ON
        // the card and tilt with it. Same order as the flat path: blurs, then sprites, then the
        // pointer sharp on top.
        if !blurBoxes.isEmpty {
            card = privacyBlurLayer(card, boxes: blurBoxes, contentRect: contentRect)
        }
        if !annotations.isEmpty {
            card = annotationLayers(annotations, contentRect: contentRect, over: card,
                                    includeSpotlights: false)
        }
        if let cursor {
            card = drawCursor(cursor, contentRect: contentRect, canvasSize: canvasSize, over: card)
        }

        // 2. Pin the extent to exactly `cardRect`. `CIPerspectiveTransform` maps its INPUT's
        //    extent corners onto the four points it is given, so the extent has to be the rect
        //    those points were computed from — no more, no less.
        let padded = card.composited(over: clear).cropped(to: cardRect)

        // 3. Warp. The corners are `cardRect`'s, projected through the SAME camera (centre and
        //    distance) that `MotionTilt.tiltedCorners(rect: contentRect,)` would use. Because the
        //    projection is a homography, that single warp lands the interior content rect exactly
        //    on its own tilted corners while giving the filter the padded extent it needs.
        let corners = MotionTilt.project(cardRect, tilt: tilt,
                                         about: CGPoint(x: contentRect.midX, y: contentRect.midY),
                                         distance: MotionTilt.cameraDistance(for: contentRect))
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = padded
        warp.topLeft = corners.tl
        warp.topRight = corners.tr
        warp.bottomLeft = corners.bl
        warp.bottomRight = corners.br
        let warped = warp.outputImage ?? padded

        var out = background
        // 4. Shadow from the WARPED card's own silhouette, so it follows the tilted outline
        //    instead of the flat path's axis-aligned rounded rect. Same alpha, blur sigma and
        //    downward offset the flat shadow uses; same silhouette recipe as `drawCursor` and
        //    `webcamLayer`. The card's transparent gutter is what keeps the blur from smearing.
        if settings.shadow.opacity > 0 {
            let silhouette = warped.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: settings.shadow.opacity),
            ])
            out = silhouette
                .applyingGaussianBlur(sigma: layout.shadowBlurSigma)
                .transformed(by: .init(translationX: 0, y: -layout.shadowOffsetY)) // y-up: down
                .composited(over: out)
        }

        // 5. The card itself, then spotlights.
        out = warped.composited(over: out)
        // NOTE: spotlights stay on the flat STAGE. Their dim layer covers the whole canvas —
        // background and padding included — so it cannot ride the card, and punching the holes
        // before the warp would tilt the dim along with them. The cost is that a spotlight hole's
        // edges can disagree with the tilted content underneath by a pixel or two at full
        // deflection; accepted (≤4° of tilt moves the content edge under 1% of the card's width).
        // The pointer is inside the card, so unlike the flat path it sits UNDER the dim here.
        if !annotations.isEmpty {
            out = spotlightAnnotationLayers(annotations, contentRect: contentRect, over: out)
        }
        return out
    }

    /// Transparent gutter kept around the content rect before warping.
    ///
    /// It has to cover everything on the card that can reach past `contentRect`, which is only
    /// the synthetic pointer: `drawCursor` hangs the image down-right from the tip by about one
    /// pointer height `h`, and crops that image's own drop shadow a further `h` beyond it — 2h in
    /// total. The ×1.25 puts that shadow's crop edge strictly inside the gutter rather than on it.
    /// Nothing else needs room: annotation sprites and privacy blurs are already clipped to
    /// `contentRect`, and the card's drop shadow is derived from the warped silhouette afterwards.
    /// The 8 px floor guarantees a gutter even with no cursor at all, so the perspective resample
    /// always has real transparent pixels to interpolate against instead of clamped edge pixels.
    private func cardPadding(cursor: CursorFrame?, canvasSize: CGSize) -> CGFloat {
        let pointerHeight = CGFloat(cursor?.sizeFraction ?? 0) * canvasSize.height
        return max(8, 2.5 * pointerHeight).rounded(.up)
    }
}
