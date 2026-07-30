import AudioPipeline
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

    public init(schemaVersion: Int, createdAt: Date, screen: TrackRef,
                webcam: TrackRef? = nil, mic: TrackRef? = nil, systemAudio: TrackRef? = nil,
                renderSettings: RenderSettings, audioSettings: AudioSettings) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.screen = screen
        self.webcam = webcam
        self.mic = mic
        self.systemAudio = systemAudio
        self.renderSettings = renderSettings
        self.audioSettings = audioSettings
    }
}
