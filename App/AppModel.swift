import Combine
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

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // `engine` is a nested ObservableObject: its own @Published changes only emit on
        // `engine.objectWillChange`, not `self.objectWillChange`. Views that observe only
        // `model` (RecorderPanelView, the MenuBarExtra label) would otherwise never
        // re-render when `engine.state` changes. Forward the signal so they do.
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Called by OnboardingView after re-checking permission status, so views observing
    /// only `model` (not the view-local @State in OnboardingView) also re-render — e.g.
    /// RecorderPanelView switching out of the onboarding branch once everything's granted.
    func permissionsChanged() {
        objectWillChange.send()
    }

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
