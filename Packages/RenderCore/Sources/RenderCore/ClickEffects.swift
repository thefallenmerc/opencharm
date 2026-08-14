import CoreGraphics

/// Which animated effect (if any) plays at each recorded click position. `pulse` is today's only
/// behavior (the pointer's own shrink/spring haptic, `CursorPulse`) — everything else is a new,
/// purely additive layer drawn under the cursor.
public enum ClickEffectKind: String, Sendable, CaseIterable {
    case none, pulse, ripple, sonar, sparkle, spotlight

    /// `nil` (not yet set) or an unrecognized raw value (a newer app version's effect, opened in
    /// an older build) both fall back to `.pulse` — today's look, never a silent "nothing".
    public static func resolve(_ raw: String?) -> ClickEffectKind {
        raw.flatMap(ClickEffectKind.init(rawValue:)) ?? .pulse
    }
}

/// Deterministic, stateless click-effect geometry: pure functions of `(t, clicks)`. Every value
/// returned here is already resolved into drawable units (normalized content-space point, radius
/// as a fraction of canvas height, alpha, …) — `Compositor+ClickEffects.swift` turns them into
/// pixels using memoized unit sprites, per the identity contract (`nil`/"pulse" stays byte-for-
/// byte identical to the pre-effects renderer).
public enum ClickEffects {
    /// One expanding-ring instance alive at a given instant (ripple/sonar).
    public struct Ring: Equatable, Sendable {
        /// Normalized content space (same space as `ClickEvent.point`).
        public var point: CGPoint
        /// Fraction of canvas height.
        public var radius: Double
        public var alpha: Double
        /// Fraction of canvas height. NOTE: rendering approximates this — see
        /// `Compositor+ClickEffects.ringLayer`'s doc comment for why the drawn stroke width
        /// scales with the ring instead of independently easing from thick to thin.
        public var lineWidth: Double
        public init(point: CGPoint, radius: Double, alpha: Double, lineWidth: Double) {
            self.point = point; self.radius = radius; self.alpha = alpha; self.lineWidth = lineWidth
        }
    }

    /// One 8-way sparkle burst's spoke, alive at a given instant.
    public struct Spoke: Equatable, Sendable {
        public var point: CGPoint
        /// Radians; the 8 spokes of one burst are `i * .pi / 4` for `i in 0..<8`.
        public var angle: Double
        /// Fraction of canvas height.
        public var innerR: Double
        /// Fraction of canvas height.
        public var outerR: Double
        public var alpha: Double
        public var lineWidth: Double
        public init(point: CGPoint, angle: Double, innerR: Double, outerR: Double, alpha: Double,
                   lineWidth: Double) {
            self.point = point; self.angle = angle; self.innerR = innerR; self.outerR = outerR
            self.alpha = alpha; self.lineWidth = lineWidth
        }
    }

    /// One click's ring animation: radius eases 0.02→0.09 (fraction of canvas height), alpha
    /// 0.9→0, stroke ratio 0.006→0.002, over `life` seconds via the smoothstep idiom
    /// `CursorPulse` already uses.
    static let rippleLife = 0.6
    private static let radiusStart = 0.02, radiusEnd = 0.09
    private static let alphaStart = 0.9, alphaEnd = 0.0
    private static let lineWidthStart = 0.006, lineWidthEnd = 0.002

    /// Every ring alive at `t`. `ripple` emits one ring per click; `sonar` emits `sonarCount`
    /// rings per click, each staggered `sonarStagger` seconds behind the last, all sharing the
    /// same envelope/life as a single ripple ring. Other kinds emit nothing — `pulse`'s haptic
    /// lives entirely in `CursorPulse`, unaffected by this type.
    static let sonarStagger = 0.15
    static let sonarCount = 3

    public static func rings(at t: Double, clicks: [ClickEvent], kind: ClickEffectKind) -> [Ring] {
        switch kind {
        case .ripple:
            return clicks.compactMap { click in
                let dt = t - click.time
                guard dt >= 0, dt <= rippleLife else { return nil }
                return ring(point: click.point, dt: dt)
            }
        case .sonar:
            var out: [Ring] = []
            out.reserveCapacity(clicks.count * sonarCount)
            for click in clicks {
                for i in 0..<sonarCount {
                    let dt = t - click.time - Double(i) * sonarStagger
                    guard dt >= 0, dt <= rippleLife else { continue }
                    out.append(ring(point: click.point, dt: dt))
                }
            }
            return out
        case .none, .pulse, .sparkle, .spotlight:
            return []
        }
    }

    private static func ring(point: CGPoint, dt: Double) -> Ring {
        let f = smooth(dt / rippleLife)
        return Ring(point: point,
                   radius: lerp(radiusStart, radiusEnd, f),
                   alpha: lerp(alphaStart, alphaEnd, f),
                   lineWidth: lerp(lineWidthStart, lineWidthEnd, f))
    }

    /// One click's sparkle burst: 8 fixed-angle spokes (`i * .pi / 4`), radial extent easing
    /// 0.015→0.05 (fraction of canvas height) with a fixed-ratio inner/outer gap, alpha 1→0, over
    /// `sparkleLife` seconds.
    ///
    /// Returned in groups of exactly `sparkleCount` (8) consecutive elements per active click, in
    /// click order — `Compositor+ClickEffects.spokeLayer` relies on this invariant to composite
    /// one burst sprite per click instead of re-deriving the grouping from point/alpha equality.
    static let sparkleLife = 0.45
    static let sparkleCount = 8
    private static let extentStart = 0.015, extentEnd = 0.05
    /// Spoke length as a fraction of its own outer radius — keeps a visible segment (not a dot)
    /// at every point in the ease. Not specified by name in the design brief; chosen to read as a
    /// short dash, same visual family as the reference "spoke" sparkle.
    private static let innerRatio = 0.55
    private static let spokeLineWidth = 0.005

    public static func spokes(at t: Double, clicks: [ClickEvent]) -> [Spoke] {
        var out: [Spoke] = []
        out.reserveCapacity(clicks.count * sparkleCount)
        for click in clicks {
            let dt = t - click.time
            guard dt >= 0, dt <= sparkleLife else { continue }
            let f = smooth(dt / sparkleLife)
            let outerR = lerp(extentStart, extentEnd, f)
            let innerR = outerR * innerRatio
            let alpha = 1 - f
            for i in 0..<sparkleCount {
                out.append(Spoke(point: click.point, angle: Double(i) * .pi / 4,
                                innerR: innerR, outerR: outerR, alpha: alpha,
                                lineWidth: spokeLineWidth))
            }
        }
        return out
    }

    /// `pulse` gating: the click-shrink haptic (`CursorPulse.scale`) plays for every kind except
    /// `.none`, including the new ring/spoke/spotlight effects (they compose with the pulse, not
    /// replace it) — only `.none` turns it off (scale pinned to 1).
    public static func pulseEnabled(_ kind: ClickEffectKind) -> Bool { kind != .none }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
