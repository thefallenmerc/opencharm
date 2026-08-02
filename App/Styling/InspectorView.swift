import RenderCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        Form {
            Section("Background") {
                Picker("Style", selection: backgroundKind) {
                    Text("Gradient").tag("gradient")
                    Text("Color").tag("solid")
                    Text("Image…").tag("image")
                }
                if backgroundKind.wrappedValue == "solid" {
                    ColorPicker("Color", selection: solidColor, supportsOpacity: false)
                }
                if backgroundKind.wrappedValue == "image" {
                    Button("Choose Image…") { chooseImage() }
                }
            }
            Section("Canvas") {
                slider("Padding", $model.renderSettings.paddingFraction, 0...0.25)
                slider("Corner radius", $model.renderSettings.cornerRadiusFraction, 0...0.2)
                slider("Shadow", $model.renderSettings.shadow.opacity, 0...1)
            }
            Section("Webcam") {
                Toggle("Show webcam", isOn: $model.renderSettings.webcam.visible)
                slider("Size", $model.renderSettings.webcam.size, 0.1...0.5)
                slider("Roundness", $model.renderSettings.webcam.roundness, 0...1)
                Picker("Position", selection: cornerPreset) {
                    Text("Bottom right").tag("br"); Text("Bottom left").tag("bl")
                    Text("Top right").tag("tr"); Text("Top left").tag("tl")
                    Text("Custom").tag("custom")
                }
                Text("Tip: drag the bubble in the preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                Toggle("Remove noise", isOn: $model.audioSettings.noiseRemoval)
                Toggle("Enhance voice", isOn: $model.audioSettings.voiceEnhance)
                slider("Mic volume", $model.audioSettings.micVolume, 0...2)
                slider("System volume", $model.audioSettings.systemVolume, 0...2)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
    }

    func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(label) { Slider(value: value, in: range) }
    }

    var backgroundKind: Binding<String> {
        Binding {
            switch model.renderSettings.background {
            case .solid: "solid"; case .linearGradient: "gradient"; case .image: "image"
            }
        } set: { kind in
            switch kind {
            case "solid":
                model.renderSettings.background = .solid(RGBAColor(r: 0.12, g: 0.12, b: 0.14))
            case "gradient":
                if case .linearGradient = model.renderSettings.background { return }
                model.renderSettings.background = RenderSettings.default.background
            default:
                chooseImage()
            }
        }
    }

    var solidColor: Binding<Color> {
        Binding {
            if case .solid(let c) = model.renderSettings.background {
                return Color(red: c.r, green: c.g, blue: c.b)
            }
            return .black
        } set: { color in
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
            model.renderSettings.background = .solid(
                RGBAColor(r: c.redComponent, g: c.greenComponent, b: c.blueComponent))
        }
    }

    var cornerPreset: Binding<String> {
        Binding {
            let c = model.renderSettings.webcam.center
            switch (c.x, c.y) {
            case (0.87, 0.82): return "br"; case (0.13, 0.82): return "bl"
            case (0.87, 0.18): return "tr"; case (0.13, 0.18): return "tl"
            default: return "custom"
            }
        } set: { preset in
            let centers = ["br": CGPoint(x: 0.87, y: 0.82), "bl": CGPoint(x: 0.13, y: 0.82),
                           "tr": CGPoint(x: 0.87, y: 0.18), "tl": CGPoint(x: 0.13, y: 0.18)]
            if let c = centers[preset] { model.renderSettings.webcam.center = c }
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            model.renderSettings.background = .image(path: url.path)
        }
    }
}
