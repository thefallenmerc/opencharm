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
                let exporter = ProjectExporter(
                    timeline: try styling.timeline(forPreview: false),
                    settings: styling.renderSettings,
                    sourceCanvasSize: styling.sourceCanvasSize,
                    backgroundImage: styling.resolvedBackgroundImage())
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
