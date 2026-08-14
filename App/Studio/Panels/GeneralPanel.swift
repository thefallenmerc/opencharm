import AppKit
import RenderCore
import SwiftUI

/// The main inspector panel: layout, aspect, background, speed, zoom, canvas knobs.
struct GeneralPanel: View {
    @ObservedObject var model: StylingModel
    @State private var bgTab = "image"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PanelSection(title: "Camera Layout", subtitle: "Webcam over screen") {
                    cameraLayoutRow
                }
                PanelSection(title: "Aspect Ratio", subtitle: "Auto matches your recording") {
                    SegmentChips(options: [
                        ("Auto", AspectPreset.auto), ("16:9", .wide16x9), ("4:3", .classic4x3),
                        ("1:1", .square), ("9:16", .vertical9x16),
                    ], selection: aspect)
                }
                PanelSection(title: "Background") { backgroundPicker }
                PanelSection(title: "Playback Speed") {
                    SegmentChips(options: [("0.5×", 0.5), ("0.75×", 0.75), ("1×", 1.0),
                                           ("1.25×", 1.25), ("1.5×", 1.5), ("2×", 2.0)],
                                 selection: playbackSpeed)
                }
                PanelSection(title: "Zoom Level", subtitle: "Default for new and auto zooms") {
                    SegmentChips(options: [("1.5×", 1.5), ("1.75×", 1.75), ("2×", 2.0),
                                           ("2.25×", 2.25), ("2.5×", 2.5)],
                                 selection: zoomLevel)
                    Toggle("Zoom in on clicks", isOn: autoZoomEnabled)
                        .toggleStyle(.switch)
                        .tint(StudioTheme.accent)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                PanelSection(title: "3D Motion",
                             subtitle: "Tilts the screen toward mouse movement during zooms") {
                    Toggle("Tilt with motion", isOn: motion3DEnabled)
                        .toggleStyle(.switch)
                        .tint(StudioTheme.accent)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                    if motion3DEnabled.wrappedValue {
                        StudioSlider(label: "Strength", value: motion3DStrength, range: 0...1)
                    }
                }
                PanelSection(title: "Cinematic Blur", subtitle: "Blurs fast zoom and pan motion") {
                    StudioSlider(label: "Amount", value: motionBlur, range: 0...1)
                }
                PanelSection(title: "Canvas") {
                    StudioSlider(label: "Padding",
                                 value: $model.renderSettings.paddingFraction, range: 0...0.25)
                    StudioSlider(label: "Corner radius",
                                 value: $model.renderSettings.cornerRadiusFraction, range: 0...0.2)
                    StudioSlider(label: "Shadow",
                                 value: $model.renderSettings.shadow.opacity, range: 0...1)
                    StudioSlider(label: "Background blur", value: backgroundBlur, range: 0...1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .frame(width: 280)
        .background(StudioTheme.panelBG)
        .onAppear { bgTab = currentBackgroundKind }
    }

    // MARK: camera layout presets

    private var cameraLayoutRow: some View {
        HStack(spacing: 8) {
            layoutThumb(center: CGPoint(x: 0.13, y: 0.82), size: 0.48, visible: true)
            layoutThumb(center: CGPoint(x: 0.87, y: 0.82), size: 0.3, visible: true)
            layoutThumb(center: CGPoint(x: 0.13, y: 0.18), size: 0.3, visible: true)
            layoutThumb(center: CGPoint(x: 0.87, y: 0.18), size: 0.3, visible: true)
            layoutThumb(center: .zero, size: 0, visible: false)
        }
    }

    private func layoutThumb(center: CGPoint, size: Double, visible: Bool) -> some View {
        let webcam = model.renderSettings.webcam
        let isCurrent = webcam.visible == visible
            && (!visible || (webcam.center == center && abs(webcam.size - size) < 0.01))
        return Button {
            model.renderSettings.webcam.visible = visible
            if visible {
                model.renderSettings.webcam.center = center
                model.renderSettings.webcam.size = size
            }
        } label: {
            ZStack(alignment: alignment(for: center)) {
                RoundedRectangle(cornerRadius: 6).fill(StudioTheme.chipBG)
                if visible {
                    Circle().fill(StudioTheme.textSecondary)
                        .frame(width: size > 0.4 ? 16 : 10, height: size > 0.4 ? 16 : 10)
                        .padding(4)
                }
            }
            .frame(width: 44, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? StudioTheme.accent : StudioTheme.chipBorder,
                        lineWidth: isCurrent ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(visible ? "Webcam bubble" : "Hide webcam")
    }

    private func alignment(for center: CGPoint) -> Alignment {
        switch (center.x < 0.5, center.y < 0.5) {
        case (true, true): .topLeading
        case (false, true): .topTrailing
        case (true, false): .bottomLeading
        case (false, false): .bottomTrailing
        }
    }

    // MARK: background

    private var backgroundPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SegmentChips(options: [("Image", "image"), ("Gradient", "gradient"),
                                   ("Color", "solid")], selection: $bgTab)
            switch bgTab {
            case "image":
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(SystemWallpapers.curated, id: \.self) { url in
                        wallpaperThumb(url)
                    }
                }
                HStack {
                    Button("Pick random") {
                        if let url = SystemWallpapers.all().randomElement() {
                            model.renderSettings.background = .image(path: url.path)
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                    Button("Upload custom…") { chooseImage() }
                        .buttonStyle(ChipButtonStyle())
                }
            case "gradient":
                HStack(spacing: 8) {
                    ForEach(0..<Self.gradientPresets.count, id: \.self) { i in
                        gradientThumb(Self.gradientPresets[i])
                    }
                }
            default:
                ColorPicker("Color", selection: solidColor, supportsOpacity: false)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
    }

    private static let gradientPresets: [(RGBAColor, RGBAColor)] = [
        (RGBAColor(r: 0.28, g: 0.18, b: 0.55), RGBAColor(r: 0.10, g: 0.35, b: 0.60)),
        (RGBAColor(r: 0.95, g: 0.45, b: 0.20), RGBAColor(r: 0.85, g: 0.15, b: 0.45)),
        (RGBAColor(r: 0.05, g: 0.45, b: 0.35), RGBAColor(r: 0.10, g: 0.20, b: 0.35)),
        (RGBAColor(r: 0.55, g: 0.20, b: 0.65), RGBAColor(r: 0.15, g: 0.15, b: 0.50)),
        (RGBAColor(r: 0.10, g: 0.10, b: 0.14), RGBAColor(r: 0.30, g: 0.30, b: 0.38)),
    ]

    private func gradientThumb(_ preset: (RGBAColor, RGBAColor)) -> some View {
        let (a, b) = preset
        let selected = model.renderSettings.background
            == .linearGradient(start: a, end: b, angleDegrees: 35)
        return Button {
            model.renderSettings.background = .linearGradient(start: a, end: b, angleDegrees: 35)
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(
                    colors: [Color(red: a.r, green: a.g, blue: a.b),
                             Color(red: b.r, green: b.g, blue: b.b)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 40, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? StudioTheme.accent : StudioTheme.chipBorder,
                            lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func wallpaperThumb(_ url: URL) -> some View {
        let selected = model.renderSettings.background == .image(path: url.path)
        return Button {
            model.renderSettings.background = .image(path: url.path)
        } label: {
            Group {
                if let img = SystemWallpapers.thumbnail(url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    StudioTheme.chipBG
                }
            }
            .frame(width: 44, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? StudioTheme.accent : StudioTheme.chipBorder,
                        lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(url.deletingPathExtension().lastPathComponent)
    }

    private var currentBackgroundKind: String {
        switch model.renderSettings.background {
        case .solid: "solid"
        case .linearGradient: "gradient"
        case .image: "image"
        }
    }

    // MARK: bindings

    private var aspect: Binding<AspectPreset> {
        Binding { model.renderSettings.aspect ?? .auto }
        set: { model.renderSettings.aspect = $0 == .auto ? nil : $0 }
    }

    private var playbackSpeed: Binding<Double> {
        Binding { model.renderSettings.playbackSpeed ?? 1 }
        set: { model.renderSettings.playbackSpeed = $0 == 1 ? nil : $0 }
    }

    private var backgroundBlur: Binding<Double> {
        Binding { model.renderSettings.backgroundBlur ?? 0 }
        set: { model.renderSettings.backgroundBlur = $0 < 0.005 ? nil : $0 }
    }

    private var motionBlur: Binding<Double> {
        Binding { model.renderSettings.motionBlur ?? 0 }
        set: { model.renderSettings.motionBlur = $0 < 0.005 ? nil : $0 }
    }

    private var zoomLevel: Binding<Double> {
        Binding { model.renderSettings.autoZoom?.level ?? 2.0 }
        set: { var z = model.renderSettings.autoZoom ?? .default
               z.level = $0
               model.renderSettings.autoZoom = z
               model.regenerateAutoZooms() }
    }

    private var autoZoomEnabled: Binding<Bool> {
        Binding { model.renderSettings.autoZoom?.enabled ?? AutoZoomSettings.default.enabled }
        set: { var z = model.renderSettings.autoZoom ?? .default
               z.enabled = $0
               model.renderSettings.autoZoom = z
               model.regenerateAutoZooms() }
    }

    private var motion3DEnabled: Binding<Bool> {
        Binding { model.renderSettings.motion3D?.enabled ?? false }
        set: { enabled in
               model.renderSettings.motion3D = enabled
                   ? Motion3DSettings(enabled: true,
                                       strength: model.renderSettings.motion3D?.strength ?? 0.5)
                   : nil }
    }

    private var motion3DStrength: Binding<Double> {
        Binding { model.renderSettings.motion3D?.strength ?? 0.5 }
        set: { model.renderSettings.motion3D = Motion3DSettings(enabled: true, strength: $0) }
    }

    private var solidColor: Binding<Color> {
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

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            model.renderSettings.background = .image(path: url.path)
        }
    }
}
