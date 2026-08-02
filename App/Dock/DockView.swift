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
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.82)))
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
        HStack(spacing: 14) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: start, by: 1)) { context in
                let s = max(0, Int(context.date.timeIntervalSince(start)))
                Text(String(format: "%02d:%02d", s / 60, s % 60))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 6)
    }

    private var stoppingBar: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Finishing…").foregroundStyle(.white)
        }
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
                toggleButton(on: "video", off: "video.slash", label: "Camera",
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
                toggleButton(on: "mic", off: "mic.slash", label: "Mic",
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
