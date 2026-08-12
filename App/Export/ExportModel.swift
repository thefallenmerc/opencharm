import AppKit
import RenderCore
import SwiftUI

@MainActor
final class ExportModel: ObservableObject {
    enum Phase: Equatable { case configuring, exporting(Double), done(URL), failed(String) }

    @Published var codec: ExportCodec = .h264
    @Published var resolution: ExportResolution = .source
    @Published var phase: Phase = .configuring
    private var exporter: ProjectExporter?
    private let styling: StylingModel

    init(styling: StylingModel) { self.styling = styling }

    func begin() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = styling.package.url
            .deletingPathExtension().lastPathComponent + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        phase = .exporting(0)
        Task {
            do {
                // Export is frequently the first thing to touch a given audio-settings
                // combination, so `AudioCache.processedURL` is often a cold miss here — RNNoise
                // running synchronously on the main actor would freeze the export sheet's UI.
                // Snapshot everything the detached task needs as plain (Sendable) values, then
                // build the timeline off the main actor via the same `nonisolated` static
                // StylingModel's own rebuild paths use, and hop back onto the main actor
                // (implicit: this Task inherits @MainActor) for the phase updates below.
                let manifest = styling.package.manifest
                let packageURL = styling.package.url
                let cacheDir = styling.package.cacheDir
                let audio = styling.audioSettings
                let settings = styling.renderSettings
                let canvas = styling.sourceCanvasSize
                let bg = styling.resolvedBackgroundImage()
                let timeline = try await Task.detached {
                    try StylingModel.buildTimeline(manifest: manifest, packageURL: packageURL,
                                                   cacheDir: cacheDir, audioSettings: audio,
                                                   forPreview: false)
                }.value
                let clicks = styling.autoZoomClicks
                let cursorSamples = styling.exportCursorSamples
                let cursorImage = styling.exportCursorImage
                let cursorHandImage = styling.exportCursorHandImage
                let exporter = ProjectExporter(
                    timeline: timeline,
                    settings: settings,
                    sourceCanvasSize: canvas,
                    backgroundImage: bg,
                    clicks: clicks,
                    cursorSamples: cursorSamples,
                    cursorImage: cursorImage,
                    cursorHandImage: cursorHandImage)
                self.exporter = exporter
                try await exporter.export(
                    ExportRequest(outputURL: url, codec: codec, resolution: resolution)) { p in
                    Task { @MainActor in
                        if case .exporting = self.phase { self.phase = .exporting(p) }
                    }
                }
                phase = .done(url)
            } catch is CancellationError {
                phase = .configuring
            } catch ExportError.cancelled {
                phase = .configuring
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { exporter?.cancel() }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
