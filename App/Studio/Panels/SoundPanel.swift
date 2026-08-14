import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                PanelSection(title: "Music", subtitle: "A looping bed mixed under your audio") {
                    musicSection
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

    @ViewBuilder
    private var musicSection: some View {
        Picker("Track", selection: musicSelection) {
            Text("None").tag("none")
            ForEach(MusicLibrary.presets, id: \.id) { preset in
                Text(preset.label).tag("preset:\(preset.id)")
            }
            if let filename = customMusicFilename {
                Text(filename).tag("custom")
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()

        Button("Choose file…") { chooseMusicFile() }
            .buttonStyle(ChipButtonStyle())

        if model.audioSettings.music != nil {
            StudioSlider(label: "Music volume", value: musicVolume, range: 0...1)
            Toggle("Loop to fit", isOn: musicLoop)
        }
    }

    /// `"none"`, `"preset:<id>"`, or `"custom"` (a user-chosen file — not directly selectable
    /// from this picker; it only appears, already selected, once `setMusicFile` set it).
    private var musicSelection: Binding<String> {
        Binding {
            guard let source = model.audioSettings.music?.source else { return "none" }
            return source.hasPrefix("preset:") ? source : "custom"
        } set: { selection in
            if selection == "none" {
                model.setMusicPreset(nil)
            } else if selection.hasPrefix("preset:") {
                model.setMusicPreset(String(selection.dropFirst("preset:".count)))
            }
        }
    }

    private var customMusicFilename: String? {
        guard let source = model.audioSettings.music?.source, !source.hasPrefix("preset:")
        else { return nil }
        return source
    }

    private var musicVolume: Binding<Double> {
        Binding {
            model.audioSettings.music?.volume ?? 0.4
        } set: { newValue in
            guard var music = model.audioSettings.music else { return }
            music.volume = newValue
            model.audioSettings.music = music
        }
    }

    private var musicLoop: Binding<Bool> {
        Binding {
            model.audioSettings.music?.loop ?? true
        } set: { newValue in
            guard var music = model.audioSettings.music else { return }
            music.loop = newValue
            model.audioSettings.music = music
        }
    }

    private func chooseMusicFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            model.setMusicFile(url)
        }
    }
}
