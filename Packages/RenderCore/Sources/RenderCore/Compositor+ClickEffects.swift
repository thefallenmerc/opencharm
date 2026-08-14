import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Click-effect animations (ripple/sonar rings, sparkle bursts, the spotlight-follow dim) drawn
/// pre-zoom, content-anchored, immediately before `drawCursor` in BOTH the flat path
/// (`Compositor.render`) and the tilt card path (`Compositor+Motion3D.tiltedContentLayer`) — so
/// they magnify and tilt with the content exactly like the synthetic pointer does, and stay
/// beneath it (the pointer is always the sharpest, topmost thing).
///
/// Extension on `Compositor` so sprite rasterization shares the same `maskCache`/`maskLock`
/// discipline every other sprite in this codebase uses (squircle, annotation shapes, …) —
/// required for `render` to stay deterministic under AVFoundation's concurrent, out-of-order
/// frame requests. `ClickEffects` (geometry) is pure; this file turns that geometry into pixels.
extension Compositor {
    /// Composites every active click effect over `stage`: rings (ripple/sonar), then sparkle
    /// bursts, then — only for `kind == .spotlight` — the continuous follow-spotlight dim. A
    /// no-op (returns `stage` unchanged) whenever `rings`/`spokes` are empty and `kind !=
    /// .spotlight`, which is exactly the state every existing caller (and `nil`/"pulse") is in —
    /// the identity contract holds because this function does nothing in that case.
    func clickEffectLayer(kind: ClickEffectKind, rings: [ClickEffects.Ring],
                          spokes: [ClickEffects.Spoke], cursorPoint: CGPoint?,
                          contentRect: CGRect, canvasSize: CGSize,
                          over stage: CIImage) -> CIImage {
        var out = stage
        if !rings.isEmpty {
            out = ringLayer(rings, contentRect: contentRect, canvasSize: canvasSize, over: out)
        }
        if !spokes.isEmpty {
            out = spokeLayer(spokes, contentRect: contentRect, canvasSize: canvasSize, over: out)
        }
        if kind == .spotlight, let cursorPoint {
            out = spotlightFollowLayer(cursorPoint, contentRect: contentRect,
                                       canvasSize: canvasSize, over: out)
        }
        return out
    }

    /// Same normalized content-space → canvas-pixel mapping `drawCursor`/`Compositor+Annotations`
    /// use: `point` is top-left-origin 0…1 over the content; the canvas is CoreImage's y-up space.
    private func contentPoint(_ p: CGPoint, in contentRect: CGRect) -> CGPoint {
        CGPoint(x: contentRect.minX + p.x * contentRect.width,
               y: contentRect.minY + (1 - p.y) * contentRect.height)
    }

    private func alphaScaled(_ image: CIImage, by alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
        ])
    }

    // MARK: rings (ripple / sonar)

    /// Every ring instance reuses ONE memoized unit sprite instead of rasterizing a fresh stroke
    /// per ring: a white circle of diameter `ringUnitDiameter`, stroked at the fixed ratio
    /// `0.006/0.09` (`ClickEffects`' start-of-life stroke ratio over its max radius ratio). Per
    /// instance we scale that one sprite to `2 * radiusPx` and set alpha via `CIColorMatrix`
    /// rather than re-rasterizing at the ring's own (shrinking) line width — an approximation the
    /// design brief calls out explicitly: the drawn stroke scales down together with the ring
    /// instead of independently thinning from 0.006 to 0.002 over its life. Visually
    /// indistinguishable at the sizes these rings render at; keeps rasterization O(1) regardless
    /// of how many rings are on screen.
    private static let ringUnitDiameter: CGFloat = 256
    private static let ringUnitStrokeRatio: CGFloat = 0.006 / 0.09
    private static let spritePad: CGFloat = 8

    private func ringUnitSprite() -> CIImage {
        let key = "clickEffect:ring"
        maskLock.lock()
        if let hit = maskCache[key] { maskLock.unlock(); return hit }
        maskLock.unlock()

        let size = Self.ringUnitDiameter
        let pad = Self.spritePad
        let dim = Int((size + 2 * pad).rounded(.up))
        guard let ctx = CGContext(
            data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
        let strokePx = size * Self.ringUnitStrokeRatio
        let rect = CGRect(x: pad, y: pad, width: size, height: size)
            .insetBy(dx: strokePx / 2, dy: strokePx / 2)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(strokePx)
        ctx.addEllipse(in: rect)
        ctx.strokePath()

        guard let cg = ctx.makeImage() else { return .empty() }
        let img = CIImage(cgImage: cg)
        maskLock.lock()
        maskCache[key] = img
        maskLock.unlock()
        return img
    }

    private func ringLayer(_ rings: [ClickEffects.Ring], contentRect: CGRect, canvasSize: CGSize,
                           over stage: CIImage) -> CIImage {
        let unit = ringUnitSprite()
        var out = stage
        for ring in rings {
            guard ring.alpha > 0.001, ring.radius > 0.0001 else { continue }
            let radiusPx = CGFloat(ring.radius) * canvasSize.height
            let scale = (2 * radiusPx) / Self.ringUnitDiameter
            guard scale > 0.0001 else { continue }
            let center = contentPoint(ring.point, in: contentRect)
            let scaled = unit.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let sx = scaled.extent.minX + scaled.extent.width / 2
            let sy = scaled.extent.minY + scaled.extent.height / 2
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: center.x - sx, y: center.y - sy))
            out = alphaScaled(positioned, by: ring.alpha).composited(over: out)
        }
        return out
    }

    // MARK: sparkle spokes

    /// ONE memoized 8-spoke burst sprite (lines from an inner to an outer radius at reference
    /// ratios, angles `i * .pi/4`), reused per click the same way `ringUnitSprite` is: per
    /// instance we scale the whole burst to the click's current outer radius, position it, and
    /// set alpha — never re-rasterize per spoke, so one click stays a single composite instead of
    /// 8 rasterizations.
    private static let spokeUnitOuterR: CGFloat = 128 // local px; represents `extentEnd` (0.05)
    private static let spokeUnitInnerRatio: CGFloat = 0.55 // matches ClickEffects.innerRatio
    private static let spokeUnitStrokeWidth: CGFloat = 3

    private func spokeUnitSprite() -> CIImage {
        let key = "clickEffect:spokeBurst"
        maskLock.lock()
        if let hit = maskCache[key] { maskLock.unlock(); return hit }
        maskLock.unlock()

        let outer = Self.spokeUnitOuterR
        let inner = outer * Self.spokeUnitInnerRatio
        let pad = Self.spritePad
        let dim = Int((outer * 2 + 2 * pad).rounded(.up))
        guard let ctx = CGContext(
            data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
        let center = CGPoint(x: outer + pad, y: outer + pad)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(Self.spokeUnitStrokeWidth)
        ctx.setLineCap(.round)
        for i in 0..<ClickEffects.sparkleCount {
            let angle = Double(i) * .pi / 4
            let c = CGFloat(cos(angle)), s = CGFloat(sin(angle))
            ctx.move(to: CGPoint(x: center.x + inner * c, y: center.y + inner * s))
            ctx.addLine(to: CGPoint(x: center.x + outer * c, y: center.y + outer * s))
        }
        ctx.strokePath()

        guard let cg = ctx.makeImage() else { return .empty() }
        let img = CIImage(cgImage: cg)
        maskLock.lock()
        maskCache[key] = img
        maskLock.unlock()
        return img
    }

    /// `spokes` arrives in fixed-size groups of `ClickEffects.sparkleCount` per active click, in
    /// click order (see `ClickEffects.spokes`'s doc comment) — chunk by that count to recover one
    /// (point, alpha, outerR) triple per click without re-deriving the grouping from geometry.
    private func spokeLayer(_ spokes: [ClickEffects.Spoke], contentRect: CGRect,
                            canvasSize: CGSize, over stage: CIImage) -> CIImage {
        let unit = spokeUnitSprite()
        var out = stage
        var i = 0
        while i + ClickEffects.sparkleCount <= spokes.count {
            defer { i += ClickEffects.sparkleCount }
            guard let first = spokes[i...].first else { continue }
            guard first.alpha > 0.001, first.outerR > 0.0001 else { continue }
            let outerPx = CGFloat(first.outerR) * canvasSize.height
            let scale = outerPx / Self.spokeUnitOuterR
            guard scale > 0.0001 else { continue }
            let center = contentPoint(first.point, in: contentRect)
            let scaled = unit.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let sx = scaled.extent.minX + scaled.extent.width / 2
            let sy = scaled.extent.minY + scaled.extent.height / 2
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: center.x - sx, y: center.y - sy))
            out = alphaScaled(positioned, by: first.alpha).composited(over: out)
        }
        return out
    }

    // MARK: spotlight-follow

    /// Radius/feather as fractions of canvas height, and the dim's opacity — the brief's exact
    /// values (0.12 hole radius, ~0.02 feather, 0.45 dim), matching `spotlightLayer` in
    /// `Compositor+Annotations.swift`'s dim opacity family.
    private static let spotlightRadiusRatio = 0.12
    private static let spotlightFeatherRatio = 0.02
    private static let spotlightDimOpacity = 0.45

    /// A soft-edged circular hole, memoized per (radiusPx, featherPx) — those only change with
    /// canvas size, not per frame, so this rasterizes once per export/preview resolution rather
    /// than once per frame. Solid white out to `radiusPx`, gaussian-like radial fade from
    /// `radiusPx` to `radiusPx + featherPx`, transparent beyond.
    private func spotlightHoleUnit(radiusPx: CGFloat, featherPx: CGFloat) -> CIImage {
        let key = "clickEffect:spotlightHole:\(Int(radiusPx.rounded())):\(Int(featherPx.rounded()))"
        maskLock.lock()
        if let hit = maskCache[key] { maskLock.unlock(); return hit }
        maskLock.unlock()

        let outer = radiusPx + featherPx
        let dim = Int((outer * 2).rounded(.up))
        guard dim > 0, let ctx = CGContext(
            data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                      CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors,
                                        locations: [0, 1]) else { return .empty() }
        let center = CGPoint(x: CGFloat(dim) / 2, y: CGFloat(dim) / 2)
        // `.drawsBeforeStartLocation` fills everything inside `radiusPx` with the start color
        // (solid, opaque) instead of leaving it untouched/transparent.
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: radiusPx,
                               endCenter: center, endRadius: outer,
                               options: .drawsBeforeStartLocation)

        guard let cg = ctx.makeImage() else { return .empty() }
        let img = CIImage(cgImage: cg)
        maskLock.lock()
        maskCache[key] = img
        maskLock.unlock()
        return img
    }

    /// Dims the whole content area (matching `spotlightLayer`'s full-stage dim) and punches a
    /// soft hole centered on the CURRENT cursor point via `CISourceOutCompositing` — the same
    /// hole-punch technique `Compositor+Annotations.spotlightLayer` uses for annotation
    /// spotlights, reused here so both stacking safely is a property of the compositing model
    /// (source-out over source-out) rather than anything this function has to coordinate.
    private func spotlightFollowLayer(_ cursorPoint: CGPoint, contentRect: CGRect,
                                      canvasSize: CGSize, over stage: CIImage) -> CIImage {
        let radiusPx = CGFloat(Self.spotlightRadiusRatio) * canvasSize.height
        let featherPx = CGFloat(Self.spotlightFeatherRatio) * canvasSize.height
        guard radiusPx > 0.5 else { return stage }
        let unit = spotlightHoleUnit(radiusPx: radiusPx, featherPx: featherPx)
        let center = contentPoint(cursorPoint, in: contentRect)
        let ux = unit.extent.minX + unit.extent.width / 2
        let uy = unit.extent.minY + unit.extent.height / 2
        let hole = unit.transformed(by: CGAffineTransform(
            translationX: center.x - ux, y: center.y - uy))
        let dimLayer = CIImage(color: CIColor(red: 0, green: 0, blue: 0,
                                              alpha: Self.spotlightDimOpacity))
            .cropped(to: stage.extent)
        let punched = dimLayer.applyingFilter("CISourceOutCompositing",
                                              parameters: [kCIInputBackgroundImageKey: hole])
        return punched.composited(over: stage)
    }
}
