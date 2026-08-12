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
                             cursorImage: CIImage? = nil,
                             cursorHandImage: CIImage? = nil,
                             retimeForExport: Bool = false) async throws -> BuiltComposition {
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

        // Playback speed: preview leaves the composition at 1x (AVPlayer.defaultRate handles it);
        // export bakes the retiming in, so every time-domain input scales with it.
        let speed = settings.playbackSpeed ?? 1
        var zoomSegments = settings.zooms.map { $0.map(\.segment) }
            ?? AutoZoom.segments(clicks: clicks, settings: settings.autoZoom ?? .default)
        var samples = cursorSamples
        var clickTimes = clicks.map(\.time).sorted()
        if retimeForExport, abs(speed - 1) > 0.001 {
            let full = CMTimeRange(start: .zero, duration: composition.duration)
            composition.scaleTimeRange(
                full,
                toDuration: CMTime(seconds: full.duration.seconds / speed,
                                   preferredTimescale: 600))
            zoomSegments = zoomSegments.map { $0.scaled(by: 1 / speed) }
            samples = samples.map {
                CursorSample(time: $0.time / speed, point: $0.point, cursorType: $0.cursorType)
            }
            clickTimes = clickTimes.map { $0 / speed }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CharmVideoCompositor.self
        videoComposition.renderSize = canvasSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = [CharmInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            screenTrackID: screenID, webcamTrackID: webcamID,
            settings: settings, backgroundImage: backgroundImage,
            zoomSegments: zoomSegments,
            cursorSamples: samples, cursorImage: cursorImage,
            cursorHandImage: cursorHandImage,
            cursorSize: settings.cursorSize ?? 0.04,
            clickTimes: clickTimes)]

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
