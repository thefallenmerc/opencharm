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
    /// Playhead position and clip length (composition seconds) — drive the Studio timeline.
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    let player = AVPlayer()
    private(set) var package: ProjectPackage
    private(set) var sourceCanvasSize = CGSize(width: 1920, height: 1080)
    /// Recorded clicks mapped to normalized screen space, loaded once. Used to seed auto-zooms.
    private(set) var autoZoomClicks: [ClickEvent] = []
    /// All pointer samples (moves + clicks), for focusing a manual zoom on the cursor location.
    private(set) var cursorSamples: [(time: Double, point: CGPoint)] = []
    private var videoDebounce: Task<Void, Never>?
    private var audioDebounce: Task<Void, Never>?
    private var saveDebounce: Task<Void, Never>?
    private var timeObserver: Any?

    init(package: ProjectPackage) {
        self.package = package
        self.renderSettings = package.manifest.renderSettings
        self.audioSettings = package.manifest.audioSettings
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.currentTime = t.seconds }
        }
        Task { await initialLoad() }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    private func initialLoad() async {
        autoZoomClicks = ClickTrack.load(package: package)
        cursorSamples = ClickTrack.loadCursor(package: package)
        // Seed the editable timeline zooms from clicks the first time this project is opened.
        if renderSettings.zooms == nil {
            let auto = AutoZoom.segments(clicks: autoZoomClicks,
                                         settings: renderSettings.autoZoom ?? .default)
            renderSettings.zooms = specs(from: auto, manual: false)
        }
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

    // MARK: Timeline zooms & transport

    var zooms: [ZoomSpec] { renderSettings.zooms ?? [] }

    private func specs(from segments: [ZoomSegment], manual: Bool) -> [ZoomSpec] {
        segments.map {
            ZoomSpec(id: UUID().uuidString, start: $0.start, end: $0.end,
                     easeIn: $0.easeIn, easeOut: $0.easeOut, focus: $0.focus,
                     scale: $0.scale, manual: manual)
        }
    }

    /// Centroid of the cursor path within [start,end] (falls back to the last known position, then
    /// the centre) — a manual zoom's focus.
    func focus(in start: Double, end: Double) -> CGPoint {
        let lo = min(start, end), hi = max(start, end)
        var pts = cursorSamples.filter { $0.time >= lo && $0.time <= hi }.map(\.point)
        if pts.isEmpty, let last = cursorSamples.last(where: { $0.time <= hi })?.point { pts = [last] }
        guard !pts.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
    }

    /// Adds a manual zoom spanning [start,end], focused on the cursor location over that span.
    @discardableResult
    func addZoom(start: Double, end: Double) -> ZoomSpec {
        let lo = max(0, min(start, end)), hi = min(max(duration, 0.3), max(start, end))
        let spec = ZoomSpec(id: UUID().uuidString, start: lo, end: max(lo + 0.3, hi),
                            easeIn: 0.4, easeOut: 0.5, focus: focus(in: lo, end: hi),
                            scale: 2.0, manual: true)
        renderSettings.zooms = (zooms + [spec]).sorted { $0.start < $1.start }
        return spec
    }

    func updateZoom(_ spec: ZoomSpec) {
        guard zooms.contains(where: { $0.id == spec.id }) else { return }
        var s = spec
        s.manual = true // an edit protects it from click-regeneration
        renderSettings.zooms = zooms.map { $0.id == s.id ? s : $0 }.sorted { $0.start < $1.start }
    }

    func setZoomLevel(_ id: String, scale: Double) {
        guard var s = zooms.first(where: { $0.id == id }) else { return }
        s.scale = min(3, max(1.5, scale))
        updateZoom(s)
    }

    func deleteZoom(_ id: String) {
        renderSettings.zooms = zooms.filter { $0.id != id }
    }

    /// Re-seeds the click-derived (non-manual) zooms from the current auto-zoom settings, keeping any
    /// manual ones. Called when the auto-zoom toggle/level/speed change or on explicit regenerate.
    func regenerateAutoZooms() {
        let manual = zooms.filter(\.manual)
        let auto = (renderSettings.autoZoom?.enabled ?? false)
            ? specs(from: AutoZoom.segments(clicks: autoZoomClicks,
                                            settings: renderSettings.autoZoom ?? .default),
                    manual: false)
            : []
        renderSettings.zooms = (manual + auto).sorted { $0.start < $1.start }
    }

    /// Seeks the player, clamped to the trimmed range when set.
    func seek(to time: Double) {
        let lo = renderSettings.trimStart ?? 0
        let hi = renderSettings.trimEnd ?? duration
        let t = min(max(time, lo), max(lo, hi))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
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
            duration = built.composition.duration.seconds
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
