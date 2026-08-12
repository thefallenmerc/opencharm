import SwiftUI

struct CursorPanel: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if model.hasSyntheticCursor {
                    PanelSection(title: "Pointer",
                                 subtitle: "Drawn in post — grows with zoom, easy to follow") {
                        StudioSlider(label: "Size", value: cursorSize, range: 0.02...0.09)
                    }
                } else {
                    PanelSection(title: "Pointer",
                                 subtitle: "This recording keeps the system cursor; new "
                                     + "recordings draw the synthetic pointer instead.") {
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .frame(width: 280)
        .background(StudioTheme.panelBG)
    }

    private var cursorSize: Binding<Double> {
        Binding { model.renderSettings.cursorSize ?? 0.04 }
        set: { model.renderSettings.cursorSize = $0 }
    }
}
