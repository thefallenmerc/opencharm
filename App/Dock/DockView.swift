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
        // The red dot is the Stop button (a Button consumes the mouse-down, so clicking it never
        // drags the panel); the timer is inert, so grabbing it drags the pill via the panel's
        // isMovableByWindowBackground. On hover the dot shows a stop square so it reads as clickable.
        HStack(spacing: 12) {
            Button {
                Task { await model.stopRecording() }
            } label: {
                ZStack {
                    Circle().fill(Color.red).frame(width: 11, height: 11)
                    if hoveringStop {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.white).frame(width: 5, height: 5)
                    }
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
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(pillBackground)
    }

    private var stoppingBar: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Finishing…").foregroundStyle(.white)
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
                toggleButton(on: "video", off: "video.slash", label: cameraLabel,
                             isOn: sources.cameraEnabled) {
                    model.setCameraEnabled(!sources.cameraEnabled)
                }
                .contextMenu {
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
                toggleButton(on: "mic", off: "mic.slash", label: micLabel,
                             isOn: sources.micEnabled) {
                    model.setMicEnabled(!sources.micEnabled)
                }
                .contextMenu {
                    ForEach(sources.mics, id: \.uniqueID) { d in
                        Button {
                            sources.micID = d.uniqueID
                        } label: {
                            if d.uniqueID == sources.micID {
                                Label(d.localizedName, systemImage: "checkmark")
                            } else { Text(d.localizedName) }
                        }
                    }
                }
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
