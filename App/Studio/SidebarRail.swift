import SwiftUI

enum StudioSection: String, CaseIterable, Identifiable {
    case general, cursor, sound, camera

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .cursor: "Cursor"
        case .sound: "Sound"
        case .camera: "Camera"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .cursor: "cursorarrow"
        case .sound: "speaker.wave.2"
        case .camera: "video"
        }
    }
}

/// The vertical icon rail on the window's left edge.
struct SidebarRail: View {
    @Binding var selection: StudioSection

    var body: some View {
        VStack(spacing: 6) {
            ForEach(StudioSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 16, weight: .medium))
                        Text(section.label)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(selection == section
                        ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .frame(width: 56, height: 50)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(selection == section ? StudioTheme.chipBG : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 72)
        .background(StudioTheme.windowBG)
    }
}
