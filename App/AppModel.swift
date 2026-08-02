import AppKit
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
    /// True from the moment a countdown is requested until `recordWithBubble()` finishes
    /// (whether or not recording actually started). Belt-and-braces alongside
    /// `CountdownWindow`'s own single-flight guard: keeps the Start button disabled so a
    /// second click can't even attempt to spawn a second countdown/recording.
    @Published var isCountingDown = false
    /// Window numbers of our overlay windows, excluded from capture (Task 15 populates).
    var overlayWindowNumbers: [Int] = []
    /// Set when recording finishes; Task 18's styling window observes this.
    @Published var finishedProject: ProjectPackage?
    /// Set by the menu-bar view via `@Environment(\.openWindow)`; opens the Studio window.
    var openStylingWindow: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var selfView: SelfViewWindow?
    private var diskWatchdog: Timer?
    private var didCheckRecovery = false

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
            let free = (try? ProjectLibrary.defaultDirectory
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? 0
            guard free > 2_000_000_000 else { // 2 GB floor
                lastError = "Not enough free disk space to record (need at least 2 GB)."
                return
            }
            try await engine.start(configuration: config,
                                   projectURL: ProjectLibrary.newProjectURL())
            diskWatchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, case .recording = self.engine.state else { return }
                    let free = (try? ProjectLibrary.defaultDirectory
                        .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                        .volumeAvailableCapacityForImportantUsage) ?? .max
                    if free < 1_000_000_000 {
                        self.lastError = "Disk space is running low — stop the recording soon."
                    }
                }
            }
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        selfView?.close(); selfView = nil
        diskWatchdog?.invalidate(); diskWatchdog = nil
        do {
            finishedProject = try await engine.stop()
            NSApp.activate(ignoringOtherApps: true)
            openStylingWindow?()
        }
        catch { lastError = "Could not finish recording: \(error.localizedDescription)" }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = []          // .opencharm is a directory package
        panel.directoryURL = ProjectLibrary.defaultDirectory
        if panel.runModal() == .OK, let url = panel.url,
           url.pathExtension == "opencharm",
           let pkg = try? ProjectPackage.open(at: url) {
            finishedProject = pkg
            NSApp.activate(ignoringOtherApps: true)
            openStylingWindow?()
        }
    }

    func checkRecoveryOnLaunch() {
        if let pkg = RecoveryPrompt.checkOnLaunch() {
            finishedProject = pkg
            openStylingWindow?()
        }
    }

    func checkRecoveryOnLaunchOnce() {
        guard !didCheckRecovery else { return }
        didCheckRecovery = true
        checkRecoveryOnLaunch()
    }

    func beginAreaSelection() {
        AreaSelectorWindow.present { [weak self] displayID, rect in
            self?.sources.selectedDisplayID = displayID
            self?.sources.selectedArea = rect
        }
    }

    func beginCountdownAndRecord() {
        isCountingDown = true
        CountdownWindow.present(seconds: 3) { [weak self] in
            Task {
                await self?.recordWithBubble()
                self?.isCountingDown = false
            }
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

        // Guard against a bubble orphaned by a previous failed attempt: if it were left
        // around, the line below would silently drop it from overlayWindowNumbers (which
        // only ever holds the NEWEST bubble's number), so it would stop being excluded and
        // could appear in this recording.
        selfView?.close(); selfView = nil

        let placeholder = AVCaptureVideoPreviewLayer()
        let bubble = SelfViewWindow(previewLayer: placeholder)
        if sources.cameraID != nil {
            bubble.orderFront(nil)
            selfView = bubble
        }
        overlayWindowNumbers = [bubble.windowNumber]
        await startRecording()
        guard case .recording = engine.state else {
            // startRecording() failed (or never actually started): don't leave a stray
            // bubble on screen whose window number is no longer excluded from anything.
            bubble.close()
            selfView = nil
            overlayWindowNumbers = []
            return
        }
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
