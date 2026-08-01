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
        public init(url: URL, startOffset: TimeInterval, volume: Double) {
            (self.url, self.startOffset, self.volume) = (url, startOffset, volume)
        }
    }
    public var screen: VideoTrack
    public var webcam: VideoTrack?
    public var audio: [AudioTrack]
    public init(screen: VideoTrack, webcam: VideoTrack?, audio: [AudioTrack]) {
        (self.screen, self.webcam, self.audio) = (screen, webcam, audio)
    }
}
