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
    private var videoDebounce: Task<Void, Never>?
    private var saveDebounce: Task<Void, Never>?

    init(package: ProjectPackage) {
        self.package = package
        self.renderSettings = package.manifest.renderSettings
        self.audioSettings = package.manifest.audioSettings
        Task { await initialLoad() }
    }

    private func initialLoad() async {
        if let track = try? await AVURLAsset(url: package.screenURL)
            .loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            sourceCanvasSize = size
        }
        await rebuildComposition()
    }

    /// Raw or cache-processed audio depending on toggles. forPreview=false is identical today;
    /// kept as a parameter so export always states its intent explicitly.
    func timeline(forPreview: Bool) throws -> MediaTimeline {
        var audio: [MediaTimeline.AudioTrack] = []
        if let mic = package.manifest.mic {
            let url = try AudioCache.processedURL(
                for: package.url.appendingPathComponent(mic.filename),
                cacheDir: package.cacheDir,
                denoise: audioSettings.noiseRemoval, enhance: audioSettings.voiceEnhance)
            audio.append(.init(url: url, startOffset: mic.startOffset,
                               volume: audioSettings.micVolume))
        }
        if let sys = package.manifest.systemAudio {
            // System audio never gets voice processing — only volume.
            audio.append(.init(url: package.url.appendingPathComponent(sys.filename),
                               startOffset: sys.startOffset,
                               volume: audioSettings.systemVolume))
        }
        return MediaTimeline(
            screen: .init(url: package.screenURL,
                          startOffset: package.manifest.screen.startOffset),
            webcam: package.manifest.webcam.map {
                .init(url: package.url.appendingPathComponent($0.filename),
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
            // Cache generation may be slow the first time — hop off the main actor.
            let settings = renderSettings
            let canvas = sourceCanvasSize
            let bg = resolvedBackgroundImage()
            let timeline = try await Task.detached { [self] in
                try await MainActor.run { try self.timeline(forPreview: true) }
            }.value
            let built = try await ProjectCompositionBuilder.build(
                timeline: timeline, settings: settings, canvasSize: canvas,
                backgroundImage: bg)
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
                let built = try await ProjectCompositionBuilder.build(
                    timeline: try timeline(forPreview: true),
                    settings: renderSettings, canvasSize: sourceCanvasSize,
                    backgroundImage: resolvedBackgroundImage())
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
        Task { await rebuildComposition() }
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
