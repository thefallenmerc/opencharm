import Foundation

/// A deleted range of the recording, in original-composition seconds.
public struct CutRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { (self.start, self.end) = (start, end) }
}

/// Math for the edited clock: the timeline with cut ranges removed. Preview keeps the full
/// composition and skips cuts during playback; export removes them for real — these helpers
/// keep every time-domain input (zooms, cursor, clicks, trim) aligned after the removal.
public enum CutClock {
    static let minLength = 0.05

    /// Sorted, merged, clamped to `[0, duration]`; sub-minimum slivers dropped.
    public static func normalized(_ cuts: [CutRange], duration: Double) -> [CutRange] {
        let clamped = cuts
            .map { CutRange(start: max(0, min($0.start, duration)),
                            end: max(0, min($0.end, duration))) }
            .filter { $0.end - $0.start >= minLength }
            .sorted { $0.start < $1.start }
        var merged: [CutRange] = []
        for cut in clamped {
            if var last = merged.last, cut.start <= last.end {
                last.end = max(last.end, cut.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(cut)
            }
        }
        return merged
    }

    /// Original-clock time → edited clock (with `cuts` removed). Times inside a cut collapse to
    /// the cut's start. `cuts` must be normalized.
    public static func map(_ t: Double, cuts: [CutRange]) -> Double {
        var removed = 0.0
        for cut in cuts {
            if t >= cut.end { removed += cut.end - cut.start }
            else if t > cut.start { removed += t - cut.start }
            else { break }
        }
        return t - removed
    }

    /// A zoom segment carried onto the edited clock: nil when the cut swallowed it whole;
    /// otherwise start/end/keys mapped (a straddling segment shrinks) and eases capped to fit.
    public static func remap(_ segment: ZoomSegment, cuts: [CutRange]) -> ZoomSegment? {
        var s = segment
        s.start = map(segment.start, cuts: cuts)
        s.end = map(segment.end, cuts: cuts)
        guard s.end - s.start >= minLength else { return nil }
        s.focusKeys = segment.focusKeys.map { FocusKey(time: map($0.time, cuts: cuts),
                                                       point: $0.point) }
        let d = s.end - s.start
        s.easeIn = min(s.easeIn, d / 2)
        s.easeOut = min(s.easeOut, d / 2)
        return s
    }
}
