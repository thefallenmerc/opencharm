import AppKit
import CoreImage
import RenderCore
import SwiftUI

struct CursorPanel: View {
    @ObservedObject var model: StylingModel
    private static let styleColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if model.hasSyntheticCursor {
                    PanelSection(title: "Pointer",
                                 subtitle: "Drawn in post — grows with zoom, easy to follow") {
                        StudioSlider(label: "Size", value: cursorSize, range: 0.02...0.09)
                    }
                    PanelSection(title: "Style") {
                        LazyVGrid(columns: Self.styleColumns, spacing: 8) {
                            ForEach(CursorStyle.allCases) { style in
                                styleSwatch(style)
                            }
                        }
                    }
                    PanelSection(title: "Click effect") {
                        SegmentChips(options: [
                            ("None", ClickEffectKind.none), ("Pulse", .pulse),
                            ("Ripple", .ripple), ("Sonar", .sonar),
                            ("Sparkle", .sparkle), ("Spotlight", .spotlight),
                        ], selection: clickEffect)
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

    private var selectedStyle: CursorStyle {
        CursorStyle(rawValue: model.renderSettings.cursorStyle ?? "classic") ?? .classic
    }

    private var clickEffect: Binding<ClickEffectKind> {
        Binding {
            ClickEffectKind.resolve(model.renderSettings.clickEffect)
        } set: {
            model.renderSettings.clickEffect = $0 == .pulse ? nil : $0.rawValue
        }
    }

    private func styleSwatch(_ style: CursorStyle) -> some View {
        let selected = selectedStyle == style
        return Button {
            model.renderSettings.cursorStyle = style == .classic ? nil : style.rawValue
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(StudioTheme.chipBG)
                    Image(nsImage: Self.thumbnail(style.art.arrow))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
                .frame(width: 70, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? StudioTheme.accent : StudioTheme.chipBorder,
                            lineWidth: selected ? 2 : 1))
                Text(style.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
    }

    /// Renders a `CIImage` to an `NSImage` for SwiftUI display (swatch previews only — the
    /// compositor itself never converts through AppKit).
    private static func thumbnail(_ image: CIImage) -> NSImage {
        let rep = NSCIImageRep(ciImage: image)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
