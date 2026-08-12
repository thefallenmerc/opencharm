import RenderCore
import SwiftUI

struct CameraPanel: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PanelSection(title: "Webcam") {
                    Toggle("Show webcam", isOn: $model.renderSettings.webcam.visible)
                        .toggleStyle(.switch)
                        .tint(StudioTheme.accent)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                    StudioSlider(label: "Size",
                                 value: $model.renderSettings.webcam.size, range: 0.1...0.6)
                    StudioSlider(label: "Roundness",
                                 value: $model.renderSettings.webcam.roundness, range: 0...1)
                    StudioSlider(label: "Content zoom", value: contentZoom, range: 1...2)
                }
                PanelSection(title: "Position", subtitle: "Tip: drag the bubble in the preview") {
                    SegmentChips(options: [("↙", "bl"), ("↘", "br"), ("↖", "tl"), ("↗", "tr")],
                                 selection: cornerPreset)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .frame(width: 280)
        .background(StudioTheme.panelBG)
    }

    private var contentZoom: Binding<Double> {
        Binding { model.renderSettings.webcam.contentZoom ?? 1 }
        set: { model.renderSettings.webcam.contentZoom = $0 < 1.005 ? nil : $0 }
    }

    private var cornerPreset: Binding<String> {
        Binding {
            let c = model.renderSettings.webcam.center
            switch (c.x, c.y) {
            case (0.87, 0.82): return "br"
            case (0.13, 0.82): return "bl"
            case (0.87, 0.18): return "tr"
            case (0.13, 0.18): return "tl"
            default: return "custom"
            }
        } set: { preset in
            let centers = ["br": CGPoint(x: 0.87, y: 0.82), "bl": CGPoint(x: 0.13, y: 0.82),
                           "tr": CGPoint(x: 0.87, y: 0.18), "tl": CGPoint(x: 0.13, y: 0.18)]
            if let c = centers[preset] { model.renderSettings.webcam.center = c }
        }
    }
}
