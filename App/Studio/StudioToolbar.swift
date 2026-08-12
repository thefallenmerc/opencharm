import SwiftUI

/// Screen-Charm-style title strip: icon cluster left (after the traffic lights), project name
/// centered, primary actions right. Sits under the transparent titlebar.
struct StudioToolbar: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                Text(model.projectName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(".charmproj")
                    .font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
                if model.hasUnsavedChanges {
                    Circle().fill(StudioTheme.textSecondary)
                        .frame(width: 6, height: 6)
                        .padding(.leading, 2)
                        .help("Edited since last save")
                }
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 70) // clear the traffic lights
                iconButton("folder", help: "Open project…") {
                    AppModel.shared?.openProjectPanel()
                }
                iconButton("arrow.uturn.backward", help: "Undo") { model.undoEdit() }
                    .disabled(!model.canUndo)
                    .opacity(model.canUndo ? 1 : 0.35)
                    .keyboardShortcut("z", modifiers: .command)
                iconButton("arrow.uturn.forward", help: "Redo") { model.redoEdit() }
                    .disabled(!model.canRedo)
                    .opacity(model.canRedo ? 1 : 0.35)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Spacer()
                Button {
                    AppModel.shared?.showDock()
                } label: {
                    Label("New recording", systemImage: "record.circle")
                }
                .buttonStyle(ChipButtonStyle())
                Button {
                    model.showExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .keyboardShortcut("e")
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 52)
        .background(StudioTheme.windowBG)
    }

    private func iconButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
