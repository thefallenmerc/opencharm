import AppKit
import CoreImage
import RenderCore

/// The cursor styles offered in the Cursor panel. Each resolves to a `CursorArt` — the art plus
/// its hotspot(s) — computed once and cached, since the polygon/gradient/emoji rasterization in
/// `CursorImage` isn't free and the art never changes for a given style.
enum CursorStyle: String, CaseIterable, Identifiable {
    case classic, blackArrow, gradientArrow, halo, pencil, pointing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: "Classic"
        case .blackArrow: "Charcoal"
        case .gradientArrow: "Gradient"
        case .halo: "Halo"
        case .pencil: "Pencil"
        case .pointing: "Pointing"
        }
    }

    /// This style's art, computed once and memoized. Lock-guarded: `CursorPanel`'s swatch grid
    /// and `StylingModel.cursorArt` can both resolve a style from the main actor, and while
    /// today that's effectively single-threaded, the cache follows the same discipline
    /// `Compositor.maskCache` does rather than assume it always will be.
    var art: CursorArt {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.cache[self] { return cached }
        let art = Self.make(self)
        Self.cache[self] = art
        return art
    }

    private static let cacheLock = NSLock()
    private static var cache: [CursorStyle: CursorArt] = [:]

    private static func make(_ style: CursorStyle) -> CursorArt {
        switch style {
        case .classic:
            // MUST stay exactly what `CursorImage.make()` / `.pointingHand()` produced before
            // styles existed — the identity contract this whole feature is built on.
            return CursorArt(arrow: CursorImage.make(), hand: CursorImage.pointingHand(),
                             hotspot: .zero, handHotspot: .zero)
        case .blackArrow:
            // Same silhouette as classic, but visually distinct from it: a dark charcoal fill
            // (not pure black) with a softer, translucent white outline instead of classic's
            // fully-opaque one.
            let charcoal = CGColor(gray: 0.12, alpha: 1)
            let softWhite = CGColor(gray: 1, alpha: 0.72)
            return CursorArt(arrow: CursorImage.make(fill: charcoal, outline: softWhite),
                             hotspot: .zero)
        case .gradientArrow:
            let colors = [
                CGColor(red: 0.98, green: 0.42, blue: 0.65, alpha: 1), // pink
                CGColor(red: 0.30, green: 0.55, blue: 0.98, alpha: 1), // blue
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray, locations: [0, 1])!
            let art = CursorImage.makeGradient(gradient: gradient, start: CGPoint(x: 0, y: 0),
                                               end: CGPoint(x: 13, y: 20))
            return CursorArt(arrow: art, hotspot: .zero)
        case .halo:
            return CursorArt(arrow: CursorImage.halo(), hotspot: CGPoint(x: 0.5, y: 0.5))
        case .pencil:
            return CursorArt(arrow: CursorImage.emoji("✏️"),
                             hotspot: CGPoint(x: 0.08, y: 0.92))
        case .pointing:
            return CursorArt(arrow: CursorImage.emoji("👆"),
                             hotspot: CGPoint(x: 0.42, y: 0.04))
        }
    }
}
