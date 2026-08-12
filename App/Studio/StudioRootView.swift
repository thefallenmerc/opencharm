import SwiftUI

/// The Studio window's root: custom toolbar strip over `rail | panel | canvas + transport`.
struct StudioRootView: View {
    @ObservedObject var model: StylingModel
    @State private var section: StudioSection = .general

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar(model: model)
            HStack(spacing: 0) {
                SidebarRail(selection: $section)
                Group {
                    switch section {
                    case .general: GeneralPanel(model: model)
                    case .cursor: CursorPanel(model: model)
                    case .sound: SoundPanel(model: model)
                    case .camera: CameraPanel(model: model)
                    }
                }
                VStack(spacing: 0) {
                    StudioCanvas(model: model)
                    StudioTransport(model: model)
                }
            }
        }
        .background(StudioTheme.windowBG)
        .preferredColorScheme(.dark)
        .background { // ⌘S save, invisible — the toolbar has no Save button by design
            Button("") { Task { await model.saveProject() } }
                .keyboardShortcut("s")
                .hidden()
        }
        .alert("OpenCharm", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
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
