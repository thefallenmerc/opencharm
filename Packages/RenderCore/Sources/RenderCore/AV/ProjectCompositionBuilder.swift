import AVFoundation
import CoreImage

public struct BuiltComposition {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
}

public enum CompositionError: Error { case missingVideoTrack(URL) }

public enum ProjectCompositionBuilder {
    public static func build(timeline: MediaTimeline, settings: RenderSettings,
                             canvasSize: CGSize,
                             backgroundImage: CIImage?,
                             clicks: [ClickEvent] = [],
                             cursorSamples: [CursorSample] = [],
                             cursorImage: CIImage? = nil) async throws -> BuiltComposition {
        let composition = AVMutableComposition()

        func addVideo(_ track: MediaTimeline.VideoTrack) async throws -> CMPersistentTrackID {
            let asset = AVURLAsset(url: track.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw CompositionError.missingVideoTrack(track.url)
            }
            let compTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let range = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
            try compTrack.insertTimeRange(
                range, of: source,
                at: CMTime(seconds: track.startOffset, preferredTimescale: 600))
            return compTrack.trackID
        }

        let screenID = try await addVideo(timeline.screen)
        var webcamID: CMPersistentTrackID?
        if let webcam = timeline.webcam { webcamID = try await addVideo(webcam) }

        var mixParams: [AVMutableAudioMixInputParameters] = []
        for audio in timeline.audio {
            let asset = AVURLAsset(url: audio.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }
            let compTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let range = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
            try compTrack.insertTimeRange(
                range, of: source,
                at: CMTime(seconds: audio.startOffset, preferredTimescale: 600))
            let params = AVMutableAudioMixInputParameters(track: compTrack)
            params.setVolume(Float(audio.volume), at: .zero)
            mixParams.append(params)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CharmVideoCompositor.self
        videoComposition.renderSize = canvasSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        // Prefer the materialized, user-editable timeline zooms; fall back to computing from clicks
        // for callers that haven't seeded `settings.zooms` yet.
        let zoomSegments = settings.zooms.map { $0.map(\.segment) }
            ?? AutoZoom.segments(clicks: clicks, settings: settings.autoZoom ?? .default)
        videoComposition.instructions = [CharmInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            screenTrackID: screenID, webcamTrackID: webcamID,
            settings: settings, backgroundImage: backgroundImage,
            zoomSegments: zoomSegments,
            cursorSamples: cursorSamples, cursorImage: cursorImage,
            cursorSize: settings.cursorSize ?? 0.04)]

        var audioMix: AVAudioMix?
        if !mixParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParams
            audioMix = mix
        }
        return BuiltComposition(composition: composition.copy() as! AVComposition,
                                videoComposition: videoComposition, audioMix: audioMix)
    }
}
