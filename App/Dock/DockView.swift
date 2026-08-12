import AppKit
import Recording
import ScreenCaptureKit
import SwiftUI

struct DockView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sources: SourcePickerModel

    @State private var showWindowPicker = false
    @State private var showDisplayPicker = false
    @State private var showPermissions = false
    @State private var hoveringStop = false

    init(model: AppModel) {
        self.model = model
        self.sources = model.sources
    }

    var body: some View {
        Group {
            switch model.engine.state {
            case .recording(let startedAt):
                recordingBar(since: startedAt)
            case .stopping:
                stoppingBar
            case .idle:
                idleDock
            }
        }
        .fixedSize()
        .contextMenu {
            Picker("Frame rate", selection: $sources.fps) {
                Text("60 fps").tag(60)
                Text("30 fps").tag(30)
            }
            Divider()
            Button("Open Project…") { model.openProjectPanel() }
            Button("Quit OpenCharm") { NSApp.terminate(nil) }
        }
    }

    private func recordingBar(since start: Date) -> some View {
        recordingBarContent(since: start)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(pillBackground)
    }

    private func recordingBarContent(since start: Date) -> some View {
        // The red dot is the Stop button (a Button consumes the mouse-down, so clicking it never
        // drags the panel); the timer is inert, so grabbing it drags the pill via the panel's
        // isMovableByWindowBackground. On hover a soft red rounded backdrop appears behind the
        // dot so it reads as clickable.
        HStack(spacing: 12) {
            Button {
                Task { await model.stopRecording() }
            } label: {
                ZStack {
                    if hoveringStop {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.red.opacity(0.35))
                    }
                    Circle().fill(Color.red).frame(width: 11, height: 11)
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop recording")
            .onHover { hoveringStop = $0 }

            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 18)

            TimelineView(.periodic(from: start, by: 1)) { context in
                let s = max(0, Int(context.date.timeIntervalSince(start)))
                Text(String(format: "%02d:%02d", s / 60, s % 60))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
    }

    private var stoppingBar: some View {
        // The hidden recording bar is a sizing template: the pill keeps EXACTLY the recording
        // state's dimensions while finishing (overlay can't resize it), so the dock never
        // jumps between the two states.
        recordingBarContent(since: .now)
            .hidden()
            .overlay {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finishing…").font(.system(size: 13)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(pillBackground)
    }

    private var pillBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.black.opacity(0.9))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    var idleDock: some View {
        VStack(spacing: 10) {
            Text("What to record?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 0) {
                dockButton(symbol: "xmark", label: nil, help: "Hide dock") {
                    model.hideDock()
                }
                divider
                sourceButton(symbol: "display", label: "Display") {
                    guard gatePermissions() else { return }
                    if sources.displays.count > 1 { showDisplayPicker = true }
                    else { model.startDisplayRecording(sources.displays.first?.displayID
                                                       ?? CGMainDisplayID()) }
                }
                .popover(isPresented: $showDisplayPicker) { displayPicker }
                sourceButton(symbol: "macwindow", label: "Window") {
                    guard gatePermissions() else { return }
                    Task { await sources.refresh(); showWindowPicker = true }
                }
                .popover(isPresented: $showWindowPicker) { windowPicker }
                sourceButton(symbol: "rectangle.dashed", label: "Area") {
                    guard gatePermissions() else { return }
                    model.startAreaRecording()
                }
                divider
                deviceToggle(on: "video", off: "video.slash", label: cameraLabel,
                             isOn: sources.cameraEnabled,
                             toggle: { model.setCameraEnabled(!sources.cameraEnabled) }) {
                    if sources.cameras.isEmpty {
                        Button("No cameras found") {}.disabled(true)
                    }
                    ForEach(sources.cameras, id: \.uniqueID) { d in
                        Button {
                            sources.cameraID = d.uniqueID
                            model.refreshIdlePreview()
                        } label: {
                            if d.uniqueID == sources.cameraID {
                                Label(d.localizedName, systemImage: "checkmark")
                            } else { Text(d.localizedName) }
                        }
                    }
                }
                micTile
                toggleButton(on: "speaker.wave.2", off: "speaker.slash",
                             label: "System Audio", isOn: sources.systemAudio) {
                    sources.systemAudio.toggle()
                }
                divider
                settingsMenu
            }
            .disabled(model.isCountingDown)
            if let err = model.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .task { // transient: auto-clear after 5 s
                        try? await Task.sleep(for: .seconds(5))
                        if model.lastError == err { model.lastError = nil }
                    }
            }
        }
        .popover(isPresented: $showPermissions) {
            OnboardingView(model: model).padding(16).frame(width: 320)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.82)))
    }

    /// The selected camera/mic device names shown under the dock toggles (falls back to the
    /// generic label when nothing is selected). Long names ellipsize inside the toggle's frame.
    private var cameraLabel: String {
        sources.cameras.first { $0.uniqueID == sources.cameraID }?.localizedName ?? "Camera"
    }

    private var micLabel: String {
        sources.mics.first { $0.uniqueID == sources.micID }?.localizedName ?? "Mic"
    }

    /// Gear item at the end of the dock: frame rate, Open Project, Quit (mirrors the dock's
    /// background right-click menu as a visible control).
    private var settingsMenu: some View {
        Menu {
            Picker("Frame rate", selection: $sources.fps) {
                Text("60 fps").tag(60)
                Text("30 fps").tag(30)
            }
            Divider()
            Button("Open Project…") { model.openProjectPanel() }
            Button("Quit OpenCharm") { NSApp.terminate(nil) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "gearshape").font(.system(size: 22))
                Text("Settings").font(.system(size: 13))
            }
            .foregroundStyle(.white)
            .frame(width: 86, height: 58)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Sources need permissions; opens the onboarding popover when any are missing.
    private func gatePermissions() -> Bool {
        if model.missingPermissions.isEmpty { return true }
        showPermissions = true
        return false
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.2))
            .frame(width: 1, height: 44).padding(.horizontal, 10)
    }

    private func sourceButton(symbol: String, label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 22))
                Text(label).font(.system(size: 13))
            }
            .foregroundStyle(.white)
            .frame(width: 86, height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dockButton(symbol: String, label: String?, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, height: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggleButton(on: String, off: String, label: String, isOn: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: isOn ? on : off).font(.system(size: 22))
                Text(label).font(.system(size: 13))
                    .lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(isOn ? .white : .white.opacity(0.45))
            .frame(width: 86, height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A source tile whose body toggles on/off (same footprint as `toggleButton`) with a small
    /// ▾ caret in the corner that opens a device picker. The caret is a separate hit target laid
    /// over the toggle Button, so a corner tap opens the menu while a tap anywhere else toggles.
    private func deviceToggle<Devices: View>(
        on: String, off: String, label: String, isOn: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder devices: () -> Devices
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            toggleButton(on: on, off: off, label: label, isOn: isOn, action: toggle)
            caretMenu(devices: devices)
        }
    }

    /// The small ▾ corner control that opens a device picker, shared by the camera/mic tiles.
    private func caretMenu<Devices: View>(@ViewBuilder devices: () -> Devices) -> some View {
        Menu {
            devices()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(2)
        .help("Choose device")
    }

    /// The mic tile: same toggle + ▾ device picker as the others, but the icon fills green with the
    /// live input level so it's visibly "listening".
    private var micTile: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                model.setMicEnabled(!sources.micEnabled)
            } label: {
                VStack(spacing: 6) {
                    MicLevelIcon(meter: model.micMeter, isOn: sources.micEnabled)
                    Text(micLabel).font(.system(size: 13))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(sources.micEnabled ? .white : .white.opacity(0.45))
                }
                .frame(width: 86, height: 58)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            caretMenu {
                if sources.mics.isEmpty {
                    Button("No microphones found") {}.disabled(true)
                }
                ForEach(sources.mics, id: \.uniqueID) { d in
                    Button {
                        sources.micID = d.uniqueID
                        model.refreshMicMeter()
                    } label: {
                        if d.uniqueID == sources.micID {
                            Label(d.localizedName, systemImage: "checkmark")
                        } else { Text(d.localizedName) }
                    }
                }
            }
        }
    }

    private var displayPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sources.displays, id: \.displayID) { d in
                Button("Display \(d.displayID) (\(d.width)×\(d.height))") {
                    showDisplayPicker = false
                    model.startDisplayRecording(d.displayID)
                }
            }
        }
        .padding(12)
    }

    private var windowPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sources.windows, id: \.windowID) { w in
                    Button(w.title ?? "Untitled") {
                        showWindowPicker = false
                        model.startWindowRecording(w)
                    }
                    .lineLimit(1)
                }
            }
            .padding(12)
        }
        .frame(width: 320, height: 260)
    }
}

/// A mic glyph that fills green from the bottom with the live input level — the dock's
/// "we're listening" indicator. Shows the slashed mic when the source is off.
private struct MicLevelIcon: View {
    @ObservedObject var meter: MicMeter
    let isOn: Bool

    var body: some View {
        Group {
            if isOn {
                ZStack {
                    Image(systemName: "mic").foregroundStyle(.white.opacity(0.55))
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.green)
                        .mask {
                            GeometryReader { geo in
                                Rectangle()
                                    .frame(height: geo.size.height * CGFloat(min(max(meter.level, 0), 1)))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                }
                .animation(.linear(duration: 0.08), value: meter.level)
            } else {
                Image(systemName: "mic.slash").foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 22))
    }
}
