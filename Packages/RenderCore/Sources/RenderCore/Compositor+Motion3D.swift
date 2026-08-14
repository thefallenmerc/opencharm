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
                            cursor: CursorFrame?,
                            clickEffectKind: ClickEffectKind = .pulse,
                            clickRings: [ClickEffects.Ring] = [],
                            clickSpokes: [ClickEffects.Spoke] = [],
                            over background: CIImage) -> CIImage {
        let contentRect = layout.contentRect
        let pad = cardPadding(cursor: cursor, canvasSize: canvasSize,
                              clickEffectKind: clickEffectKind)
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
            // Same click-effect-then-cursor order as the flat path, so the effects tilt and
            // magnify with the card and the pointer stays sharp on top of them. Rings and spokes
            // only: the spotlight-follow DIM is excluded here and applied to the flat stage in
            // step 5, exactly like the annotation spotlights above (a full-canvas dim baked into
            // the card would tint the card's transparent gutter — a dark fringe on the warp, and a
            // corrupted silhouette for the step-4 shadow — and would still leave the background
            // undimmed).
            card = clickEffectLayer(kind: clickEffectKind, rings: clickRings, spokes: clickSpokes,
                                    cursorPoint: cursor.point, contentRect: contentRect,
                                    canvasSize: canvasSize, includeSpotlightFollow: false,
                                    over: card)
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
        // NOTE: the spotlight-follow click dim stays on the flat STAGE for exactly the reasons
        // above — it is the same full-canvas dim, so it cannot ride the card, and its hole can
        // disagree with the tilted content underneath by a pixel or two at full deflection; the
        // same accepted cost. Applied after the annotation spotlights so the two stack in the
        // same order the flat path stacks them (annotations first, click effects on top).
        if let cursor {
            out = spotlightFollowClickLayer(kind: clickEffectKind, cursorPoint: cursor.point,
                                            contentRect: contentRect, canvasSize: canvasSize,
                                            over: out)
        }
        return out
    }

    /// Transparent gutter kept around the content rect before warping. It has to cover everything
    /// on the card that can reach past `contentRect`, because the card is cropped to this rect
    /// before the perspective warp — anything outside gets a straight, clipped edge.
    ///
    /// Two things reach out there. The synthetic pointer: `drawCursor` hangs the art off the tip
    /// (which way, and how far, depends on the hotspot — a 0 hotspot puts the whole sprite
    /// down-right of the tip, a centred one splits it), then crops that art's own drop shadow a
    /// further pointer-height `h` beyond it. And click effects: a ripple/sonar ring grows to
    /// `ClickEffects.maxReachRatio` (0.09) of the canvas height around its click point, and that
    /// point can sit exactly on the content edge — at a small cursor size the pointer term alone
    /// is only a fifth of that, which used to clip one side of the ring flat during a tilt.
    ///
    /// The ×1.25 puts the pointer shadow's crop edge strictly inside the gutter rather than on it;
    /// the click term gets a flat few pixels for the ring stroke's own antialiasing. Nothing else
    /// needs room: annotation sprites and privacy blurs are already clipped to `contentRect`, the
    /// spotlight dims never ride the card at all, and the card's own drop shadow is derived from
    /// the warped silhouette afterwards. The 8 px floor guarantees a gutter even with no cursor,
    /// so the perspective resample always has real transparent pixels to interpolate against
    /// instead of clamped edge pixels.
    private func cardPadding(cursor: CursorFrame?, canvasSize: CGSize,
                             clickEffectKind: ClickEffectKind) -> CGFloat {
        var pad: CGFloat = 8
        if let cursor {
            let h = CGFloat(cursor.sizeFraction) * canvasSize.height
            let extent = cursor.image.extent
            // A degenerate or infinite art extent falls back to square, which reproduces the
            // original `2.5 * h` exactly for a hotspot of zero.
            let aspect = (extent.isInfinite || extent.isEmpty || extent.height <= 0)
                ? 1 : extent.width / extent.height
            let overhang = max(max(cursor.hotspot.x, 1 - cursor.hotspot.x) * h * aspect,
                               max(cursor.hotspot.y, 1 - cursor.hotspot.y) * h)
            pad = max(pad, 1.25 * (overhang + h))
        }
        if ClickEffects.drawsSprites(clickEffectKind) {
            pad = max(pad, CGFloat(ClickEffects.maxReachRatio) * canvasSize.height + 4)
        }
        return pad.rounded(.up)
    }
}
