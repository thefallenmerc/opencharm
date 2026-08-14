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
                             cursorArt: CursorArt? = nil,
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
        // Music tracks are handled separately, after cut/speed retiming below — skip them here
        // so narration/system audio insert exactly as before.
        for audio in timeline.audio where audio.isMusic != true {
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
        // Single source of truth for both `clickEvents` (time + point, drives ripple/sonar/
        // sparkle) and `clickTimes` (time only, drives `CursorPulse`): one sorted+remapped pass
        // over `clicks`, with `clickTimes` derived FROM the remapped array below rather than
        // computed independently — guarantees the two stay in exact parity through cuts/speed
        // instead of two copies of the same remap silently drifting apart.
        var remappedClicks = clicks.sorted { $0.time < $1.time }
        var blurBoxes = settings.blurBoxes ?? []
        var annotations = settings.annotations ?? []

        // Deleted segments: preview keeps the full composition (playback skips them); export
        // removes them for real, shifting every time-domain input onto the edited clock.
        let cuts = CutClock.normalized(settings.cuts ?? [],
                                       duration: composition.duration.seconds)
        if retimeForExport, !cuts.isEmpty {
            for cut in cuts.reversed() {
                composition.removeTimeRange(CMTimeRange(
                    start: CMTime(seconds: cut.start, preferredTimescale: 600),
                    end: CMTime(seconds: cut.end, preferredTimescale: 600)))
            }
            zoomSegments = zoomSegments.compactMap { CutClock.remap($0, cuts: cuts) }
            samples = samples.map {
                CursorSample(time: CutClock.map($0.time, cuts: cuts), point: $0.point,
                             cursorType: $0.cursorType)
            }
            remappedClicks = remappedClicks.map {
                ClickEvent(time: CutClock.map($0.time, cuts: cuts), point: $0.point)
            }
            blurBoxes = blurBoxes.compactMap { box in
                var b = box
                b.start = CutClock.map(box.start, cuts: cuts)
                b.end = CutClock.map(box.end, cuts: cuts)
                return b.end - b.start > 0.05 ? b : nil // fully inside a removed segment
            }
            annotations = annotations.compactMap { spec in
                var a = spec
                a.start = CutClock.map(spec.start, cuts: cuts)
                a.end = CutClock.map(spec.end, cuts: cuts)
                return a.end - a.start > 0.05 ? a : nil // fully inside a removed segment
            }
        }
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
            remappedClicks = remappedClicks.map { ClickEvent(time: $0.time / speed, point: $0.point) }
            blurBoxes = blurBoxes.map { $0.scaled(by: 1 / speed) }
            annotations = annotations.map { $0.scaled(by: 1 / speed) }
        }

        // Background music: inserted AFTER the cuts/speed retiming above, sized to the FINAL
        // `composition.duration` — so the bed is one continuous asset laid onto the already-
        // edited/retimed clock, never chopped by a cut mid-track and never itself time-scaled
        // by `scaleTimeRange` (that call already ran, against the tracks present before this
        // point; content added afterward is untouched by it).
        //
        // Accepted v1 divergence (iron rule 3): in PREVIEW (`retimeForExport == false`) the
        // cuts/speed blocks above are skipped, so `composition.duration` here is still the raw,
        // un-retimed recording length, and a non-1x `playbackSpeed` tempo-shifts the music bed
        // during playback only because `AVPlayer.defaultRate` scales the whole player's audio
        // output, music included. Export runs this same code after the real retime, so its
        // music bed is never tempo-shifted — export is the source of truth.
        let musicFadeInBase = 0.5   // seconds, 0 → volume
        let musicFadeOutBase = 1.5  // seconds, volume → 0
        let finalDuration = composition.duration
        for music in timeline.audio where music.isMusic == true {
            guard finalDuration > .zero else { continue }
            let asset = AVURLAsset(url: music.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }
            let sourceDuration = try await asset.load(.duration)
            guard sourceDuration > .zero else { continue }
            let compTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let loop = music.loops == true
            var cursor = CMTime.zero
            while cursor < finalDuration {
                let clipDuration = min(sourceDuration, finalDuration - cursor)
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: clipDuration), of: source, at: cursor)
                cursor = cursor + clipDuration
                if !loop { break } // single insert: truncated if longer, ends early if shorter
            }

            let params = AVMutableAudioMixInputParameters(track: compTrack)
            let totalSeconds = finalDuration.seconds
            // Proportionally shrink both ramps when the whole bed is shorter than their combined
            // length, so a very short composition still fades fully in and out.
            let fadeScale = min(1, totalSeconds / (musicFadeInBase + musicFadeOutBase))
            let fadeIn = CMTime(seconds: musicFadeInBase * fadeScale, preferredTimescale: 600)
            let fadeOut = CMTime(seconds: musicFadeOutBase * fadeScale, preferredTimescale: 600)
            let volume = Float(music.volume)
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                 timeRange: CMTimeRange(start: .zero, duration: fadeIn))
            params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: finalDuration - fadeOut,
                                                        duration: fadeOut))
            mixParams.append(params)
        }
        let clickTimes = remappedClicks.map(\.time)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CharmVideoCompositor.self
        videoComposition.renderSize = canvasSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = [CharmInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            screenTrackID: screenID, webcamTrackID: webcamID,
            settings: settings, backgroundImage: backgroundImage,
            zoomSegments: zoomSegments,
            cursorSamples: samples, cursorArt: cursorArt,
            cursorSize: settings.cursorSize ?? 0.04,
            clickTimes: clickTimes, clickEvents: remappedClicks,
            blurBoxes: blurBoxes, annotations: annotations)]

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
