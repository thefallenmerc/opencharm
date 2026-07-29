import Foundation

public struct AudioSettings: Codable, Equatable, Sendable {
    public var noiseRemoval: Bool
    public var voiceEnhance: Bool
    public var micVolume: Double    // 0–2
    public var systemVolume: Double // 0–2

    public init(noiseRemoval: Bool, voiceEnhance: Bool, micVolume: Double, systemVolume: Double) {
        (self.noiseRemoval, self.voiceEnhance) = (noiseRemoval, voiceEnhance)
        (self.micVolume, self.systemVolume) = (micVolume, systemVolume)
    }

    public static let `default` = AudioSettings(
        noiseRemoval: true, voiceEnhance: true, micVolume: 1.0, systemVolume: 1.0)
}
