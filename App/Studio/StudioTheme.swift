import SwiftUI

/// Design tokens for the Studio chrome — one source of truth, no ad-hoc colors in views.
enum StudioTheme {
    static let windowBG = Color(.sRGB, red: 0.051, green: 0.051, blue: 0.063)   // #0D0D10
    static let panelBG = Color(.sRGB, red: 0.102, green: 0.102, blue: 0.118)    // #1A1A1E
    static let chipBG = Color(.sRGB, red: 0.137, green: 0.137, blue: 0.157)     // #232328
    static let chipBorder = Color.white.opacity(0.08)
    static let accent = Color(.sRGB, red: 0.42, green: 0.36, blue: 0.91)        // indigo (Export)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let cornerRadius: CGFloat = 10
}

/// The dark rounded "chip" every toolbar/transport button uses.
struct ChipButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                .fill(prominent ? StudioTheme.accent : StudioTheme.chipBG))
            .overlay(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                .stroke(StudioTheme.chipBorder, lineWidth: prominent ? 0 : 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Horizontal chip row bound to one value — the reference's segmented control idiom.
struct SegmentChips<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == option.value
                            ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(selection == option.value ? StudioTheme.chipBG : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(selection == option.value
                                ? StudioTheme.accent : StudioTheme.chipBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Titled block inside an inspector panel ("Aspect Ratio", "Background", …).
struct PanelSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

/// Labeled slider row in the panel style.
struct StudioSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
            Slider(value: $value, in: range)
                .tint(StudioTheme.accent)
        }
    }
}
