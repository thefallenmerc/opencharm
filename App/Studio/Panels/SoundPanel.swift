import SwiftUI

struct SoundPanel: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PanelSection(title: "Voice") {
                    Toggle("Remove noise", isOn: $model.audioSettings.noiseRemoval)
                    Toggle("Enhance voice", isOn: $model.audioSettings.voiceEnhance)
                }
                PanelSection(title: "Levels") {
                    StudioSlider(label: "Mic volume",
                                 value: $model.audioSettings.micVolume, range: 0...2)
                    StudioSlider(label: "System volume",
                                 value: $model.audioSettings.systemVolume, range: 0...2)
                }
            }
            .toggleStyle(.switch)
            .tint(StudioTheme.accent)
            .font(.system(size: 12))
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .frame(width: 280)
        .background(StudioTheme.panelBG)
    }
}
