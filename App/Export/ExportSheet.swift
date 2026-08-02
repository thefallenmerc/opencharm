import RenderCore
import SwiftUI

struct ExportSheet: View {
    @StateObject var model: ExportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .configuring:
                Form {
                    Picker("Codec", selection: $model.codec) {
                        Text("H.264 (compatible)").tag(ExportCodec.h264)
                        Text("HEVC (smaller)").tag(ExportCodec.hevc)
                    }
                    Picker("Resolution", selection: $model.resolution) {
                        Text("Source").tag(ExportResolution.source)
                        Text("1080p").tag(ExportResolution.fullHD1080)
                        Text("4K").tag(ExportResolution.uhd4K)
                    }
                }
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Export…") { model.begin() }.keyboardShortcut(.defaultAction)
                }
            case .exporting(let p):
                ProgressView(value: p) { Text("Exporting… \(Int(p * 100))%") }
                Button("Cancel") { model.cancel() }
            case .done(let url):
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    Button("Reveal in Finder") { model.revealInFinder(url) }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Label("Export failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message).font(.caption)
                Button("OK") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
