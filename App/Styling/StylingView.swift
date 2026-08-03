import SwiftUI

struct StylingView: View {
    @StateObject var model: StylingModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.hasUnsavedChanges {
                    Text("Edited").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") { Task { await model.saveProject() } }
                    .keyboardShortcut("s")
                Button("Save As…") { Task { await model.saveProjectAs() } }
                Button("Export…") { model.showExport = true } // property added in Task 19
                    .keyboardShortcut("e")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .disabled(model.isSaving)
            Divider()
            HStack(spacing: 0) {
                InspectorView(model: model)
                Divider()
                ZStack {
                    PlayerView(player: model.player)
                    WebcamDragOverlay(model: model)
                    if model.processingAudio {
                        ProgressView("Processing audio…")
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(minWidth: 480, minHeight: 320)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            StudioTimeline(model: model)
        }
        .alert("OpenCharm", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.showExport) {
            ExportSheet(model: ExportModel(styling: model))
        }
        .overlay {
            if model.isSaving {
                ProgressView("Saving…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
