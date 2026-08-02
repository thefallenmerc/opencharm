import AudioPipeline
import CoreGraphics
import Foundation
import RenderCore

public struct TrackRef: Codable, Equatable, Sendable {
    public var filename: String
    public var startOffset: TimeInterval
    public init(filename: String, startOffset: TimeInterval) {
        (self.filename, self.startOffset) = (filename, startOffset)
    }
}

public struct ProjectManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var createdAt: Date
    public var screen: TrackRef
    public var webcam: TrackRef?
    public var mic: TrackRef?
    public var systemAudio: TrackRef?
    public var renderSettings: RenderSettings
    public var audioSettings: AudioSettings
    /// Global desktop rect (top-left origin, points) the screen video covers — used to map recorded
    /// click coordinates into the screen's normalized space for auto-zoom. `nil` for window captures
    /// and for projects recorded before this field existed. Optional/additive: old manifests decode
    /// this as `nil`.
    public var captureRect: CGRect?

    public init(schemaVersion: Int, createdAt: Date, screen: TrackRef,
                webcam: TrackRef? = nil, mic: TrackRef? = nil, systemAudio: TrackRef? = nil,
                renderSettings: RenderSettings, audioSettings: AudioSettings,
                captureRect: CGRect? = nil) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.screen = screen
        self.webcam = webcam
        self.mic = mic
        self.systemAudio = systemAudio
        self.renderSettings = renderSettings
        self.audioSettings = audioSettings
        self.captureRect = captureRect
    }
}
