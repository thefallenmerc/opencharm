import Recording
import ScreenCaptureKit
import SwiftUI

struct RecorderPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sources: SourcePickerModel

    init(model: AppModel) {
        self.model = model
        self.sources = model.sources
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .recording = model.engine.state {
                recordingBody
            } else if case .stopping = model.engine.state {
                stoppingBody
            } else if !model.missingPermissions.isEmpty {
                OnboardingView(model: model)
            } else {
                idleBody
            }
            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 300)
        .task { await sources.refresh() }
    }

    var idleBody: some View {
        Group {
            Picker("", selection: $sources.mode) {
                ForEach(SourcePickerModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)

            switch sources.mode {
            case .fullScreen:
                Picker("Display", selection: $sources.selectedDisplayID) {
                    ForEach(sources.displays, id: \.displayID) {
                        Text("Display \($0.displayID)").tag($0.displayID)
                    }
                }
            case .window:
                Picker("Window", selection: $sources.selectedWindow) {
                    Text("Choose…").tag(nil as SCWindow?)
                    ForEach(sources.windows, id: \.windowID) {
                        Text($0.title ?? "Untitled").tag($0 as SCWindow?)
                    }
                }
            case .area:
                HStack {
                    Button(sources.selectedArea == nil ? "Select Area…" : "Reselect Area…") {
                        model.beginAreaSelection() // Task 15
                    }
                    if let r = sources.selectedArea {
                        Text("\(Int(r.width))×\(Int(r.height))").foregroundStyle(.secondary)
                    }
                }
            }

            Picker("Camera", selection: $sources.cameraID) {
                Text("Off").tag(nil as String?)
                ForEach(sources.cameras, id: \.uniqueID) {
                    Text($0.localizedName).tag($0.uniqueID as String?)
                }
            }
            Picker("Microphone", selection: $sources.micID) {
                Text("Off").tag(nil as String?)
                ForEach(sources.mics, id: \.uniqueID) {
                    Text($0.localizedName).tag($0.uniqueID as String?)
                }
            }
            Toggle("System audio", isOn: $sources.systemAudio)
            Picker("Frame rate", selection: $sources.fps) {
                Text("60 fps").tag(60); Text("30 fps").tag(30)
            }

            Button {
                model.beginCountdownAndRecord() // Task 15 (countdown → startRecording)
            } label: {
                Label("Start Recording", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(sources.mode == .window && sources.selectedWindow == nil
                      || sources.mode == .area && sources.selectedArea == nil
                      || model.isCountingDown)
        }
    }

    var recordingBody: some View {
        Button {
            Task { await model.stopRecording() }
        } label: {
            Label("Stop Recording", systemImage: "stop.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.defaultAction)
    }

    var stoppingBody: some View {
        Button {
            // no-op: already stopping, finalization is in flight
        } label: {
            HStack {
                Label("Stopping…", systemImage: "stop.circle.fill")
                Spacer()
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(true)
    }
}
