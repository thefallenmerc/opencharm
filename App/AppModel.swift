import AVFoundation
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
    private var selfView: SelfViewWindow?

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
        selfView?.close(); selfView = nil
        do { finishedProject = try await engine.stop() }
        catch { lastError = "Could not finish recording: \(error.localizedDescription)" }
    }

    func beginAreaSelection() {
        AreaSelectorWindow.present { [weak self] displayID, rect in
            self?.sources.selectedDisplayID = displayID
            self?.sources.selectedArea = rect
        }
    }

    func beginCountdownAndRecord() {
        CountdownWindow.present(seconds: 3) { [weak self] in
            Task { await self?.recordWithBubble() }
        }
    }

    private func recordWithBubble() async {
        // The bubble must exist BEFORE start so its window number can be excluded —
        // but the preview layer only exists after the engine builds the webcam session.
        // Order: pre-create an empty panel? No: exclusion only needs the number at
        // SCContentFilter build time inside engine.start(). So: create bubble first
        // with a placeholder layer requirement → instead we start, then show bubble,
        // accepting the bubble may appear in the first frames? NOT acceptable.
        //
        // Resolution used here: WebcamRecorder is constructed inside engine.start()
        // before SCShareableContent is queried only if the bubble exists first.
        // Simplest correct sequencing:
        //   1. Build the bubble window empty (no preview layer yet).
        //   2. Pass its windowNumber via overlayWindowNumbers.
        //   3. Start engine; when webcamPreviewLayer becomes available, attach it.
        let placeholder = AVCaptureVideoPreviewLayer()
        let bubble = SelfViewWindow(previewLayer: placeholder)
        if sources.cameraID != nil {
            bubble.orderFront(nil)
            selfView = bubble
        }
        overlayWindowNumbers = [bubble.windowNumber]
        await startRecording()
        if let layer = engine.webcamPreviewLayer, let view = bubble.contentView {
            placeholder.removeFromSuperlayer()
            layer.frame = view.bounds
            layer.cornerRadius = view.bounds.width / 2
            layer.masksToBounds = true
            view.layer?.addSublayer(layer)
        } else if sources.cameraID == nil {
            bubble.close(); selfView = nil
        }
    }
}
