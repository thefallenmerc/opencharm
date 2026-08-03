import AppKit
import AVFoundation
import Combine
import ProjectStore
import Recording
import ScreenCaptureKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    /// Self-registering hook so `AppDelegate.applicationDidFinishLaunching` can reach the app's
    /// one `AppModel` instance without SwiftUI plumbing (it drives launch recovery, the dock,
    /// and the webcam bubble from there). Set once, in `init()`, well before AppKit dispatches
    /// the launch notification. See `OpenCharmApp.swift`.
    static weak var shared: AppModel?

    let engine = RecordingEngine()
    let sources = SourcePickerModel()
    /// Owns the live idle camera preview and the one self-view bubble (idle + recording).
    let cameraPreview = CameraPreviewController()
    /// Live microphone input level (0…1) for the dock's mic meter.
    let micMeter = MicMeter()

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
    private var diskWatchdog: Timer?
    private var didCheckRecovery = false

    init() {
        Self.shared = self
        // `engine` is a nested ObservableObject: its own @Published changes only emit on
        // `engine.objectWillChange`, not `self.objectWillChange`. Views that observe only
        // `model` (DockView, the MenuBarExtra label) would otherwise never
        // re-render when `engine.state` changes. Forward the signal so they do.
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Keep the camera/mic lists live as devices are plugged in or removed, and re-point the
        // idle preview if the selected camera vanished or a better one appeared. Debounced because
        // a single plug event can emit several notifications.
        NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)
            .merge(with: NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification))
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.sources.refreshDevices()
                    self.refreshIdlePreview()
                    self.refreshMicMeter()
                }
            }
            .store(in: &cancellables)
    }

    /// Called by OnboardingView after re-checking permission status, so views observing
    /// only `model` (not the view-local @State in OnboardingView) also re-render — e.g.
    /// the dock's permission popover reflecting the new status once everything's granted.
    func permissionsChanged() {
        objectWillChange.send()
    }

    /// Opens (or brings forward) the Studio window showing `pkg`. The single entry
    /// point for stop-flow, launch recovery, and Open Project.
    func openStudio(_ pkg: ProjectPackage, savedArchive: URL? = nil) {
        studio.show(package: pkg, savedArchive: savedArchive)
    }

    /// Quit-time save prompt for an open Studio project with unsaved work.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        studio.promptSaveForTermination()
    }

    var missingPermissions: [PermissionKind] {
        var needed: [PermissionKind] = [.screenRecording]
        if sources.cameraEnabled, sources.cameraID != nil { needed.append(.camera) }
        if sources.micEnabled, sources.micID != nil { needed.append(.microphone) }
        return needed.filter { PermissionsService.status($0) != .granted }
    }

    /// Launch-time UI: called from AppDelegate after the recovery check. Requests
    /// camera permission on first launch, then starts the live self-view.
    func launchUI() {
        showDock()
        Task {
            await sources.refresh()
            if PermissionsService.status(.camera) == .undetermined {
                _ = await PermissionsService.request(.camera)
            }
            refreshIdlePreview()
            refreshMicMeter()
        }
    }

    /// (Re)starts or stops the idle preview to match the camera toggle + permission.
    func refreshIdlePreview() {
        guard case .idle = engine.state else { return } // recording owns the camera
        if sources.cameraEnabled, PermissionsService.status(.camera) == .granted {
            cameraPreview.startIdlePreview(deviceID: sources.cameraID)
        } else {
            cameraPreview.stopIdleSession()
            cameraPreview.hideBubble()
        }
    }

    /// Starts/stops the idle mic meter to match the mic toggle, permission, and idle state.
    func refreshMicMeter() {
        guard case .idle = engine.state else { micMeter.stop(); return } // recording owns the mic
        if sources.micEnabled, sources.micID != nil,
           PermissionsService.status(.microphone) == .granted {
            micMeter.start(deviceID: sources.micID)
        } else {
            micMeter.stop()
        }
    }

    func setCameraEnabled(_ on: Bool) {
        sources.cameraEnabled = on
        refreshIdlePreview()
    }

    func setMicEnabled(_ on: Bool) {
        sources.micEnabled = on
        refreshMicMeter()
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
        diskWatchdog?.invalidate(); diskWatchdog = nil
        do {
            let pkg = try await engine.stop()
            openStudio(pkg)
        }
        catch { lastError = "Could not finish recording: \(error.localizedDescription)" }
        refreshIdlePreview() // resume the live idle preview whether stop succeeded or failed
        refreshMicMeter()
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

    private var dock: DockPanel?

    func showDock() {
        if dock == nil { dock = DockPanel(content: DockView(model: self)) }
        dock?.orderFront(nil)
    }

    func hideDock() {
        dock?.orderOut(nil)
    }

    func startDisplayRecording(_ id: CGDirectDisplayID) {
        sources.mode = .fullScreen
        sources.selectedDisplayID = id
        beginCountdownAndRecord()
    }

    func startWindowRecording(_ window: SCWindow) {
        sources.mode = .window
        sources.selectedWindow = window
        beginCountdownAndRecord()
    }

    /// Area flow becomes click-to-go: select, then straight into the countdown.
    func startAreaRecording() {
        AreaSelectorWindow.present { [weak self] displayID, rect in
            guard let self else { return }
            sources.mode = .area
            sources.selectedDisplayID = displayID
            sources.selectedArea = rect
            beginCountdownAndRecord()
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
        // The bubble (owned by cameraPreview) must exist with its window number in
        // overlayWindowNumbers before engine.start builds the capture filter; the
        // engine's own preview layer is swapped in after start. The idle session must
        // stop first so the recording session can open the camera device.
        let cameraActive = sources.cameraEnabled && sources.cameraID != nil
        cameraPreview.stopIdleSession()
        micMeter.stop() // the engine is about to take the mic device
        if cameraActive {
            cameraPreview.ensureBubble()
        } else {
            cameraPreview.hideBubble()
        }
        overlayWindowNumbers = [cameraPreview.bubbleWindowNumber].compactMap { $0 }
        await startRecording()
        guard case .recording = engine.state else {
            overlayWindowNumbers = []
            refreshIdlePreview() // resume live preview after a failed start
            refreshMicMeter()
            return
        }
        if cameraActive, let layer = engine.webcamPreviewLayer {
            cameraPreview.attachRecordingLayer(layer)
        }
    }
}
