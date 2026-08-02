import AudioPipeline
import AVFoundation
import CoreImage
import ProjectStore
import RenderCore
import SwiftUI

@MainActor
final class StylingModel: ObservableObject {
    @Published var renderSettings: RenderSettings { didSet { renderSettingsChanged() } }
    @Published var audioSettings: AudioSettings { didSet { audioSettingsChanged() } }
    @Published var processingAudio = false
    @Published var errorMessage: String?
    @Published var showExport = false // Task 19 attaches the sheet

    let player = AVPlayer()
    private(set) var package: ProjectPackage
    private(set) var sourceCanvasSize = CGSize(width: 1920, height: 1080)
    /// Recorded clicks mapped to normalized screen space, loaded once. Drives auto-zoom in both
    /// preview and export. Empty when the project has no capture rect (e.g. window captures).
    private(set) var autoZoomClicks: [ClickEvent] = []
    private var videoDebounce: Task<Void, Never>?
    private var audioDebounce: Task<Void, Never>?
    private var saveDebounce: Task<Void, Never>?

    init(package: ProjectPackage) {
        self.package = package
        self.renderSettings = package.manifest.renderSettings
        self.audioSettings = package.manifest.audioSettings
        Task { await initialLoad() }
    }

    private func initialLoad() async {
        autoZoomClicks = ClickTrack.load(package: package)
        if let track = try? await AVURLAsset(url: package.screenURL)
            .loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            sourceCanvasSize = size
        }
        await rebuildComposition()
    }

    /// Raw or cache-processed audio depending on toggles. forPreview=false is identical today;
    /// kept as a parameter so export always states its intent explicitly.
    ///
    /// Thin `@MainActor` wrapper around the `nonisolated` static below, kept for callers (and
    /// tests) that only need it once the audio cache is already warm — a warm
    /// `AudioCache.processedURL` is just a fast file-existence check. Every hot path that can
    /// hit a COLD cache (`rebuildComposition()`, `rebuildVideoComposition()`, and
    /// `ExportModel.begin()`) must instead call `buildTimeline` directly from a detached task,
    /// never this method: a cache miss runs RNNoise synchronously and can take real time,
    /// which must never block the main actor.
    func timeline(forPreview: Bool) throws -> MediaTimeline {
        try Self.buildTimeline(manifest: package.manifest, packageURL: package.url,
                               cacheDir: package.cacheDir, audioSettings: audioSettings,
                               forPreview: forPreview)
    }

    /// Plain-value variant of `timeline(forPreview:)` with no dependency on `self` or the main
    /// actor, so it can run entirely inside a detached task. `AudioCache.processedURL` can take
    /// real time on a cache miss (RNNoise on minutes of audio) and that must never block the
    /// main actor — which a method isolated to `self` (a `@MainActor` instance) cannot avoid,
    /// since calling it at all requires being on the main actor.
    nonisolated static func buildTimeline(manifest: ProjectManifest, packageURL: URL,
                                          cacheDir: URL, audioSettings: AudioSettings,
                                          forPreview: Bool) throws -> MediaTimeline {
        var audio: [MediaTimeline.AudioTrack] = []
        if let mic = manifest.mic {
            let url = try AudioCache.processedURL(
                for: packageURL.appendingPathComponent(mic.filename),
                cacheDir: cacheDir,
                denoise: audioSettings.noiseRemoval, enhance: audioSettings.voiceEnhance)
            audio.append(.init(url: url, startOffset: mic.startOffset,
                               volume: audioSettings.micVolume))
        }
        if let sys = manifest.systemAudio {
            // System audio never gets voice processing — only volume.
            audio.append(.init(url: packageURL.appendingPathComponent(sys.filename),
                               startOffset: sys.startOffset,
                               volume: audioSettings.systemVolume))
        }
        return MediaTimeline(
            screen: .init(url: packageURL.appendingPathComponent(manifest.screen.filename),
                          startOffset: manifest.screen.startOffset),
            webcam: manifest.webcam.map {
                .init(url: packageURL.appendingPathComponent($0.filename),
                      startOffset: $0.startOffset)
            },
            audio: audio)
    }

    func resolvedBackgroundImage() -> CIImage? {
        guard case .image(let path) = renderSettings.background else { return nil }
        if path.hasPrefix("preset:") {
            let name = String(path.dropFirst("preset:".count))
            guard let url = Bundle.main.url(forResource: name, withExtension: "png")
            else { return nil }
            return CIImage(contentsOf: url)
        }
        return CIImage(contentsOf: URL(fileURLWithPath: path))
    }

    func rebuildComposition() async {
        processingAudio = true
        defer { processingAudio = false }
        do {
            // Snapshot everything the detached task needs as plain (Sendable) values — it must
            // not touch `self`, a `@MainActor` instance, or cache generation (which can take
            // real time on a cache miss) would hop back onto the main actor to reach it.
            let manifest = package.manifest
            let packageURL = package.url
            let cacheDir = package.cacheDir
            let audio = audioSettings
            let settings = renderSettings
            let canvas = sourceCanvasSize
            let bg = resolvedBackgroundImage()
            let clicks = autoZoomClicks
            let timeline = try await Task.detached {
                try Self.buildTimeline(manifest: manifest, packageURL: packageURL,
                                       cacheDir: cacheDir, audioSettings: audio,
                                       forPreview: true)
            }.value
            // A newer audio-settings change may have superseded us while we were off doing
            // cache generation — don't clobber the player with a stale result.
            guard !Task.isCancelled else { return }
            let built = try await ProjectCompositionBuilder.build(
                timeline: timeline, settings: settings, canvasSize: canvas,
                backgroundImage: bg, clicks: clicks)
            guard !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            let time = player.currentTime()
            player.replaceCurrentItem(with: item)
            if time.isValid, time.seconds > 0 {
                await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } catch {
            errorMessage = "Preview failed: \(error.localizedDescription)"
        }
    }

    func rebuildVideoComposition() {
        videoDebounce?.cancel()
        videoDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled, let item = player.currentItem else { return }
            do {
                // Same reasoning as rebuildComposition(): a cold `AudioCache` entry runs
                // RNNoise synchronously and can take real time, so `buildTimeline` must run
                // off the main actor even though only render (not audio) settings changed
                // here — the cache can still be cold the first time this fires. Snapshot
                // everything the detached task needs as plain (Sendable) values.
                let manifest = package.manifest
                let packageURL = package.url
                let cacheDir = package.cacheDir
                let audio = audioSettings
                let settings = renderSettings
                let canvas = sourceCanvasSize
                let bg = resolvedBackgroundImage()
                let clicks = autoZoomClicks
                let timeline = try await Task.detached {
                    try Self.buildTimeline(manifest: manifest, packageURL: packageURL,
                                           cacheDir: cacheDir, audioSettings: audio,
                                           forPreview: true)
                }.value
                guard !Task.isCancelled else { return }
                let built = try await ProjectCompositionBuilder.build(
                    timeline: timeline, settings: settings, canvasSize: canvas,
                    backgroundImage: bg, clicks: clicks)
                guard !Task.isCancelled else { return }
                item.videoComposition = built.videoComposition
                if player.rate == 0 { // refresh the paused frame
                    await player.seek(to: player.currentTime(),
                                      toleranceBefore: .zero, toleranceAfter: .zero)
                }
            } catch { errorMessage = "Preview failed: \(error.localizedDescription)" }
        }
    }

    private func renderSettingsChanged() {
        rebuildVideoComposition()
        persist()
    }

    private func audioSettingsChanged() {
        audioDebounce?.cancel()
        audioDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            await self.rebuildComposition()
        }
        persist()
    }

    private func persist() {
        saveDebounce?.cancel()
        saveDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            package.manifest.renderSettings = renderSettings
            package.manifest.audioSettings = audioSettings
            try? package.saveManifest()
        }
    }
}
