import Foundation

/// Background music: a bundled preset or a user-chosen file, mixed under the recording audio as
/// a continuous bed. Additive/optional on `AudioSettings` — projects saved before this feature
/// decode `music` as `nil`.
public struct MusicSettings: Codable, Equatable, Sendable {
    /// `"preset:<name>"` for a bundled track (resolved against `App/Resources/Music`), or a
    /// package-relative filename (e.g. `"music.m4a"`) for a user-chosen file copied into the
    /// project package.
    public var source: String
    public var volume: Double   // 0…1
    public var loop: Bool

    public init(source: String, volume: Double = 0.4, loop: Bool = true) {
        (self.source, self.volume, self.loop) = (source, volume, loop)
    }
}

public struct AudioSettings: Codable, Equatable, Sendable {
    public var noiseRemoval: Bool
    public var voiceEnhance: Bool
    public var micVolume: Double    // 0–2
    public var systemVolume: Double // 0–2
    /// Background music bed. Additive/optional: `nil` = no music.
    public var music: MusicSettings?

    public init(noiseRemoval: Bool, voiceEnhance: Bool, micVolume: Double, systemVolume: Double,
                music: MusicSettings? = nil) {
        (self.noiseRemoval, self.voiceEnhance) = (noiseRemoval, voiceEnhance)
        (self.micVolume, self.systemVolume) = (micVolume, systemVolume)
        self.music = music
    }

    public static let `default` = AudioSettings(
        noiseRemoval: true, voiceEnhance: true, micVolume: 1.0, systemVolume: 1.0)
}
