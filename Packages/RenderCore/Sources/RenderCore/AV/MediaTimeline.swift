import Foundation

public struct MediaTimeline: Sendable {
    public struct VideoTrack: Sendable {
        public var url: URL
        public var startOffset: TimeInterval
        public init(url: URL, startOffset: TimeInterval) {
            (self.url, self.startOffset) = (url, startOffset)
        }
    }
    public struct AudioTrack: Sendable {
        public var url: URL
        public var startOffset: TimeInterval
        public var volume: Double
        /// `true` for a background-music bed: skipped by the builder's main narration/system
        /// audio loop and instead inserted after cut/speed retiming, sized to the final
        /// composition duration. `nil`/`false` = an ordinary narration/system track.
        public var isMusic: Bool?
        /// Whether a music track repeats to fill the final composition duration. Ignored for
        /// non-music tracks.
        public var loops: Bool?
        public init(url: URL, startOffset: TimeInterval, volume: Double,
                    isMusic: Bool? = nil, loops: Bool? = nil) {
            (self.url, self.startOffset, self.volume) = (url, startOffset, volume)
            (self.isMusic, self.loops) = (isMusic, loops)
        }
    }
    public var screen: VideoTrack
    public var webcam: VideoTrack?
    public var audio: [AudioTrack]
    public init(screen: VideoTrack, webcam: VideoTrack?, audio: [AudioTrack]) {
        (self.screen, self.webcam, self.audio) = (screen, webcam, audio)
    }
}
