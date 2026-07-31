import ProjectStore
import Recording
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let engine = RecordingEngine()
    let sources = SourcePickerModel()

    @Published var lastError: String?
    /// Window numbers of our overlay windows, excluded from capture (Task 15 populates).
    var overlayWindowNumbers: [Int] = []
    /// Set when recording finishes; Task 18's styling window observes this.
    @Published var finishedProject: ProjectPackage?

    var missingPermissions: [PermissionKind] {
        var needed: [PermissionKind] = [.screenRecording]
        if sources.cameraID != nil { needed.append(.camera) }
        if sources.micID != nil { needed.append(.microphone) }
        return needed.filter { PermissionsService.status($0) != .granted }
    }

    func startRecording() async {
        guard missingPermissions.isEmpty,
              let config = sources.buildConfiguration(excludedWindowNumbers: overlayWindowNumbers)
        else { return }
        do {
            try FileManager.default.createDirectory(
                at: ProjectLibrary.defaultDirectory, withIntermediateDirectories: true)
            try await engine.start(configuration: config,
                                   projectURL: ProjectLibrary.newProjectURL())
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        do { finishedProject = try await engine.stop() }
        catch { lastError = "Could not finish recording: \(error.localizedDescription)" }
    }

    func beginAreaSelection() {} // Task 15
    func beginCountdownAndRecord() { Task { await startRecording() } } // Task 15 adds countdown
}
