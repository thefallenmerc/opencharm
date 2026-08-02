import AppKit
import AVFoundation
import Combine
import ProjectStore
import Recording
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    /// Self-registering hook so `AppDelegate.applicationDidFinishLaunching` — which runs before
    /// SwiftUI has necessarily evaluated any lazy Scene content (in particular
    /// `MenuBarExtra(.window)`'s `RecorderPanelView`, which only builds its `body` once the user
    /// actually clicks the menu bar icon) — can reach the app's one `AppModel` instance without
    /// SwiftUI plumbing. Set once, in `init()`, well before AppKit dispatches the launch
    /// notification. See `OpenCharmApp.swift`.
    static weak var shared: AppModel?

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

    /// AppKit-owned Studio window. The single vehicle for showing a finished/opened
    /// project — stop-flow, launch recovery, and Open Project all go through `openStudio`.
    private lazy var studio = StudioWindowController()

    private var cancellables: Set<AnyCancellable> = []
    private var selfView: SelfViewWindow?
    private var diskWatchdog: Timer?
    private var didCheckRecovery = false

    init() {
        Self.shared = self
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

    /// Opens (or brings forward) the Studio window showing `pkg`. The single entry
    /// point for stop-flow, launch recovery, and Open Project.
    func openStudio(_ pkg: ProjectPackage) {
        studio.show(package: pkg)
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
            let pkg = try await engine.stop()
            openStudio(pkg)
        }
        catch { lastError = "Could not finish recording: \(error.localizedDescription)" }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = []          // .opencharm is a directory package
        panel.directoryURL = ProjectLibrary.defaultDirectory
        // .OK with no URL shouldn't happen, but if it did, treat it like Cancel rather than
        // reporting a spurious error.
        guard panel.runModal() == .OK, let url = panel.url else { return } // user cancelled
        guard url.pathExtension == "opencharm" else {
            presentOpenProjectError("Not an OpenCharm project.")
            return
        }
        do {
            let pkg = try ProjectPackage.open(at: url)
            openStudio(pkg)
        } catch {
            presentOpenProjectError("Couldn't open project: \(error.localizedDescription)")
        }
    }

    /// A picked file/folder that isn't a valid `.opencharm` package used to fail silently —
    /// indistinguishable from the user cancelling the panel. Surface it both ways: `lastError`
    /// for the recorder panel's inline banner, and an immediate `NSAlert` since the user is
    /// already mid-interaction with a modal panel and expects a direct response.
    private func presentOpenProjectError(_ message: String) {
        lastError = message
        let alert = NSAlert()
        alert.messageText = "OpenCharm"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func checkRecoveryOnLaunch() {
        guard let pkg = RecoveryPrompt.checkOnLaunch() else { return }
        openStudio(pkg)
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
        // Sequencing: the bubble window must exist, with its window number already in
        // `overlayWindowNumbers`, before `startRecording()` calls `engine.start()` — window
        // exclusion is fixed at SCContentFilter build time, so a window created afterward
        // could not be retroactively excluded. Its `AVCaptureVideoPreviewLayer` isn't
        // available that early, though: it only exists once the engine has built the webcam
        // capture session. So the bubble is created first with a throwaway placeholder layer
        // (an empty `NSWindow` still gets a window number without one), and the real preview
        // layer is swapped in afterward, once `engine.webcamPreviewLayer` exists.

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
