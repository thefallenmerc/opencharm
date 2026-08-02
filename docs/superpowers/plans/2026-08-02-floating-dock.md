# Floating Recorder Dock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the menu-bar recorder panel with a Screen Charm-style floating draggable dock ("What to record?" — `✕ | Display | Window | Area ‖ Camera | Mic | System Audio`) that appears at launch with a live webcam bubble, morphs into a stop bar while recording, and demotes the menu bar to a plain menu.

**Architecture:** App-layer only. A nonactivating floating `NSPanel` hosts a SwiftUI `DockView` driven by the existing `AppModel`/`RecordingEngine` state. A `CameraPreviewController` owns an idle AVCaptureSession + the self-view bubble for both idle and recording modes (layer handoff at record start/stop). The Studio window moves from a lazy SwiftUI `Window` scene to an AppKit `StudioWindowController`, deleting the `pendingStylingOpen` workaround.

**Tech Stack:** SwiftUI + AppKit (NSPanel/NSHostingView), AVFoundation preview session. No package changes.

**Spec:** `docs/superpowers/specs/2026-08-02-floating-dock-design.md` — read before starting.

## Global Constraints

- App-layer only: **no file under `Packages/` may change.** A needed package change is a red flag — stop and report BLOCKED.
- macOS 14 deployment target; existing patterns (MainActor models, `engine.objectWillChange` forwarding in `AppModel.init`, `isReleasedWhenClosed = false` on programmatic windows) must survive every task.
- All OpenCharm windows are excluded from capture app-wide (ScreenRecorder excludes our app by bundle ID); new windows need no extra exclusion work, but the window-number fallback list (`overlayWindowNumbers`) must still carry the bubble's number (test-context fallback).
- Every task ends with `make build` (BUILD SUCCEEDED, no new warnings) and `make test` (all 4 package suites green — proves no package regressions). App-layer has no headless UI harness: launch checks + `screencapture -x` screenshots (the terminal has Screen Recording permission — Read the PNG to verify visuals) replace UI tests; interactive flows defer to the user smoke pass.
- Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Verbatim UI copy: dock title `What to record?`; menu items `Show Dock`, `Open Project…` (⌘O), `Quit OpenCharm`.

## File Structure (locked)

```
App/
  Studio/StudioWindowController.swift    NEW  T1  AppKit Studio window + per-URL StylingModel cache
  Camera/CameraPreviewController.swift   NEW  T2  idle camera session + the one self-view bubble
  Dock/DockPanel.swift                   NEW  T3  nonactivating floating panel, position persistence
  Dock/DockView.swift                    NEW  T3  idle dock UI  (T4 adds recording/stopping states)
  OpenCharmApp.swift                     MOD  T1 (drop Window scene) T3 (.menu style)
  AppModel.swift                         MOD  T1 (openStudio) T2 (camera plumbing) T3 (dock + flows)
  Styling/StylingView.swift              MOD  T1 (toolbar → header row)
  Recorder/SourcePickerModel.swift       MOD  T2 (cameraEnabled/micEnabled)
  Recorder/RecorderPanelView.swift       DEL  T3
  Recorder/SelfViewWindow.swift          MOD  T2 (layer swap helper)
docs/SMOKE.md, README.md                 MOD  T4
```

---

### Task 1: Studio window → AppKit (`StudioWindowController`)

Kills the lazy-scene/`pendingStylingOpen` workaround: recovery, stop-flow, and Open Project call one plain method.

**Files:**
- Create: `App/Studio/StudioWindowController.swift`
- Modify: `App/OpenCharmApp.swift` (delete `Window` scene, `StylingHost`, `StylingModelCache`, `.commands`)
- Modify: `App/AppModel.swift` (add `openStudio`; delete `finishedProject`, `openStylingWindow`, `pendingStylingOpen`, `openPendingStylingWindowIfNeeded`)
- Modify: `App/Styling/StylingView.swift` (`.toolbar` → in-content header; SwiftUI toolbars don't render in a plain `NSWindow`)
- Modify: `App/Recorder/RecorderPanelView.swift` (drop the `openStylingWindow` hookup from `.onAppear`)

**Interfaces:**
- Consumes: `StylingModel(package:)`, `StylingView(model:)`, `RecoveryPrompt.checkOnLaunch()`, `AppDelegate` launch hook — all existing.
- Produces: `AppModel.openStudio(_ pkg: ProjectPackage)` — the ONLY way any code opens the Studio from now on (Tasks 3–4 menu/dock call it). `StudioWindowController.show(package:)`.

- [ ] **Step 1: Create StudioWindowController**

`App/Studio/StudioWindowController.swift`:
```swift
import AppKit
import ProjectStore
import SwiftUI

/// AppKit-owned Studio window. Replaces the SwiftUI `Window` scene so any code path
/// (stop-flow, launch recovery, Open Project) can open it directly, without the
/// lazy-scene `openWindow` environment plumbing.
@MainActor
final class StudioWindowController: NSWindowController {
    /// Same-instance reuse per project URL — prevents rebuilding a StylingModel
    /// (AVPlayer + initialLoad task) every time the same project is shown.
    private var models: [URL: StylingModel] = [:]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OpenCharm Studio"
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(package: ProjectPackage) {
        let model: StylingModel
        if let existing = models[package.url] {
            model = existing
        } else {
            model = StylingModel(package: package)
            models[package.url] = model
        }
        window?.contentView = NSHostingView(rootView: StylingView(model: model))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 2: Route AppModel through openStudio**

In `App/AppModel.swift`:
1. Add near the other stored properties:
```swift
    private lazy var studio = StudioWindowController()
```
2. Add method:
```swift
    /// Opens (or brings forward) the Studio window showing `pkg`. The single entry
    /// point for stop-flow, launch recovery, and Open Project.
    func openStudio(_ pkg: ProjectPackage) {
        studio.show(package: pkg)
    }
```
3. Delete these members entirely: `@Published var finishedProject`, `var openStylingWindow` (with its `didSet`), `private var pendingStylingOpen`, `func openPendingStylingWindowIfNeeded()`.
4. `stopRecording()` — replace the success body:
```swift
        do {
            let pkg = try await engine.stop()
            openStudio(pkg)
        }
```
(`openStudio` already activates the app; drop the now-redundant `NSApp.activate` line here.)
5. `openProjectPanel()` — replace the success body:
```swift
            let pkg = try ProjectPackage.open(at: url)
            openStudio(pkg)
```
(drop its `NSApp.activate` + `openStylingWindow?()` lines.)
6. `checkRecoveryOnLaunch()` — replace the whole body:
```swift
        guard let pkg = RecoveryPrompt.checkOnLaunch() else { return }
        openStudio(pkg)
```
7. Update the big doc comment on `AppModel.shared` and `AppDelegate` if it references `pendingStylingOpen` (it references lazy MenuBarExtra content; trim to match the new reality).

- [ ] **Step 3: Slim OpenCharmApp and RecorderPanelView**

`App/OpenCharmApp.swift`: delete the `Window("OpenCharm Studio", …)` scene including `.defaultSize` and `.commands`, and delete `StylingHost` and `StylingModelCache` entirely (the controller now owns model reuse). The file keeps only `AppDelegate` + the `MenuBarExtra` scene. Note: ⌘O is temporarily unavailable — Task 3 restores it as a menu shortcut.

`App/Recorder/RecorderPanelView.swift`: in `.onAppear`, delete the `model.openStylingWindow = { … }` assignment and the `model.checkRecoveryOnLaunchOnce()` backstop call (AppDelegate owns launch recovery); keep whatever else the block does (if it becomes empty, remove the modifier).

`App/Styling/StylingView.swift`: replace the `.toolbar { ToolbarItem(placement: .primaryAction) { Button("Export…") { model.showExport = true } } }` modifier with an in-content header. Wrap the existing `HSplitView` in:
```swift
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Export…") { model.showExport = true }
                    .keyboardShortcut("e")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            // existing HSplitView goes here unchanged
        }
```
(keep `.alert` and `.sheet` modifiers attached at the same level they are now — on the outermost view).

- [ ] **Step 4: Build + behavioral check**

Run: `make build` → BUILD SUCCEEDED, no new warnings. Then create a synthetic interrupted package to prove recovery still opens the Studio at launch:
```bash
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/OpenCharm-*/Build/Products/Debug/OpenCharm.app | head -1)
mkdir -p ~/Movies/OpenCharm && python3 - <<'EOF'
# minimal fake interrupted package (manifest v1 + lock)
import json, os
p = os.path.expanduser("~/Movies/OpenCharm/RecoveryFixture.opencharm")
os.makedirs(p, exist_ok=True)
json.dump({"schemaVersion":1,"createdAt":1754000000,
  "screen":{"filename":"screen.mov","startOffset":0},
  "renderSettings":{"background":{"solid":{"_0":{"r":0.1,"g":0.1,"b":0.12,"a":1}}},
    "paddingFraction":0.06,"cornerRadiusFraction":0.02,
    "shadow":{"opacity":0.45,"radius":0.03,"offsetY":0.012},
    "webcam":{"visible":True,"center":[0.87,0.82],"size":0.24,"roundness":1}},
  "audioSettings":{"noiseRemoval":True,"voiceEnhance":True,"micVolume":1,"systemVolume":1}},
  open(p+"/project.json","w"))
open(p+"/recording.lock","w").close()
EOF
open "$APP"; sleep 3; screencapture -x /tmp/recovery-check.png
```
Read `/tmp/recovery-check.png` — the recovery alert must be visible. Click nothing; `pkill OpenCharm` and `rm -rf ~/Movies/OpenCharm/RecoveryFixture.opencharm` afterwards. (The alert blocks the run loop; killing the app is the clean exit for this fixture check.) Run `make test` — all green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(app): AppKit Studio window controller, drop lazy-scene workaround

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Camera idle preview + toggle plumbing

**Files:**
- Create: `App/Camera/CameraPreviewController.swift`
- Modify: `App/Recorder/SelfViewWindow.swift` (add `swap(to:)` helper)
- Modify: `App/Recorder/SourcePickerModel.swift` (add `cameraEnabled`/`micEnabled`, honor in `buildConfiguration`)
- Modify: `App/AppModel.swift` (launch hook, preview lifecycle, recordWithBubble refactor)
- Modify: `App/OpenCharmApp.swift` (AppDelegate calls `launchUI()`)

**Interfaces:**
- Consumes: `SelfViewWindow`, `PermissionsService`, `engine.webcamPreviewLayer`, existing `recordWithBubble` sequencing invariants (bubble + window number BEFORE `engine.start`).
- Produces (Task 3–4 rely on): `SourcePickerModel.cameraEnabled: Bool` / `micEnabled: Bool` (`@Published`, default `true`); `AppModel.launchUI()`; `AppModel.setCameraEnabled(_:)` / `setMicEnabled(_:)`; `AppModel.cameraPreview: CameraPreviewController` with `bubbleWindowNumber: Int?`.

- [ ] **Step 1: SelfViewWindow layer-swap helper**

Append inside `SelfViewWindow` (`App/Recorder/SelfViewWindow.swift`):
```swift
    /// Replaces the bubble's current preview layer with `layer` (used for the
    /// idle-session ↔ recording-session handoff).
    func swap(to layer: AVCaptureVideoPreviewLayer) {
        guard let view = contentView else { return }
        view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer.frame = view.bounds
        layer.cornerRadius = view.bounds.width / 2
        layer.masksToBounds = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
    }
```

- [ ] **Step 2: CameraPreviewController**

`App/Camera/CameraPreviewController.swift`:
```swift
import AppKit
import AVFoundation

/// Owns the idle (non-recording) camera preview session and THE self-view bubble
/// used in both idle and recording modes. The Recording package is never touched:
/// at record start the idle session stops (releasing the device), the engine's
/// recording preview layer is swapped into the same bubble, and on stop the idle
/// session resumes. A sub-second preview gap during handoff is by design.
@MainActor
final class CameraPreviewController {
    private(set) var bubble: SelfViewWindow?
    private var session: AVCaptureSession?
    private var idleLayer: AVCaptureVideoPreviewLayer?

    var bubbleWindowNumber: Int? { bubble?.windowNumber }

    /// Starts (or restarts) the idle preview on `deviceID` (nil = default camera)
    /// and shows the bubble. No-op degradation: if the device can't be opened the
    /// bubble is hidden and the app stays functional.
    func startIdlePreview(deviceID: String?) {
        stopIdleSession()
        guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) })
            ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device) else {
            hideBubble()
            return
        }
        let s = AVCaptureSession()
        s.beginConfiguration()
        guard s.canAddInput(input) else { s.commitConfiguration(); hideBubble(); return }
        s.addInput(input)
        s.commitConfiguration()
        let layer = AVCaptureVideoPreviewLayer(session: s)
        layer.videoGravity = .resizeAspectFill
        ensureBubble().swap(to: layer)
        session = s
        idleLayer = layer
        Task.detached { s.startRunning() } // blocking call; keep off the main actor
    }

    /// Stops the idle session (turns the camera light off). Bubble stays unless hidden.
    func stopIdleSession() {
        session?.stopRunning()
        session = nil
        idleLayer = nil
    }

    /// Swaps the engine's recording preview layer into the (existing) bubble.
    func attachRecordingLayer(_ layer: AVCaptureVideoPreviewLayer) {
        ensureBubble().swap(to: layer)
    }

    func hideBubble() {
        bubble?.orderOut(nil)
    }

    /// Creates the bubble on first use; re-shows it if hidden.
    @discardableResult
    func ensureBubble() -> SelfViewWindow {
        let b: SelfViewWindow
        if let bubble { b = bubble } else {
            b = SelfViewWindow(previewLayer: AVCaptureVideoPreviewLayer())
            bubble = b
        }
        b.orderFront(nil)
        return b
    }
}
```

- [ ] **Step 3: SourcePickerModel enable flags**

In `App/Recorder/SourcePickerModel.swift` add alongside the other `@Published` fields:
```swift
    /// Master switches for the dock toggles. Device *selection* (`cameraID`/`micID`)
    /// is preserved while a source is toggled off.
    @Published var cameraEnabled = true
    @Published var micEnabled = true
```
and in `buildConfiguration(excludedWindowNumbers:)` change the two arguments:
```swift
            webcamDeviceID: cameraEnabled ? cameraID : nil,
            micDeviceID: micEnabled ? micID : nil,
```

- [ ] **Step 4: AppModel — launch hook, toggle API, handoff**

In `App/AppModel.swift`:
1. Add stored property: `let cameraPreview = CameraPreviewController()`
2. Add:
```swift
    /// Launch-time UI: called from AppDelegate after the recovery check. Requests
    /// camera permission on first launch, then starts the live self-view.
    func launchUI() {
        Task {
            await sources.refresh()
            if PermissionsService.status(.camera) == .undetermined {
                _ = await PermissionsService.request(.camera)
            }
            refreshIdlePreview()
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

    func setCameraEnabled(_ on: Bool) {
        sources.cameraEnabled = on
        refreshIdlePreview()
    }

    func setMicEnabled(_ on: Bool) {
        sources.micEnabled = on
    }
```
3. Replace `recordWithBubble()`'s body with the handoff version (the sequencing invariant is unchanged: bubble + number exist BEFORE `engine.start`):
```swift
    private func recordWithBubble() async {
        // The bubble (owned by cameraPreview) must exist with its window number in
        // overlayWindowNumbers before engine.start builds the capture filter; the
        // engine's own preview layer is swapped in after start. The idle session must
        // stop first so the recording session can open the camera device.
        let cameraActive = sources.cameraEnabled && sources.cameraID != nil
        cameraPreview.stopIdleSession()
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
            return
        }
        if cameraActive, let layer = engine.webcamPreviewLayer {
            cameraPreview.attachRecordingLayer(layer)
        }
    }
```
4. In `stopRecording()`, after the `do/catch`, add `refreshIdlePreview()` (resumes idle preview whether stop succeeded or failed). Delete the now-unused `private var selfView: SelfViewWindow?` property and its `selfView?.close(); selfView = nil` line in `stopRecording()`.
5. In `missingPermissions`, the camera/mic conditions change to honor the toggles:
```swift
        if sources.cameraEnabled, sources.cameraID != nil { needed.append(.camera) }
        if sources.micEnabled, sources.micID != nil { needed.append(.microphone) }
```

- [ ] **Step 5: AppDelegate launch call**

In `App/OpenCharmApp.swift`, `applicationDidFinishLaunching` gains one line after the recovery check:
```swift
        AppModel.shared?.checkRecoveryOnLaunchOnce()
        AppModel.shared?.launchUI()
```

- [ ] **Step 6: Build + launch check**

`make build` → BUILD SUCCEEDED. Launch the built app; wait 3 s; `screencapture -x /tmp/bubble-check.png`; Read the PNG — the round webcam bubble must be visible bottom-right showing a live camera image (if this Mac's camera is unavailable/denied for the app bundle, the bubble will be absent — report which outcome you observed honestly; absence with denied permission is spec-correct degradation, not a pass of the visual check). `pkill OpenCharm`. `make test` green.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(app): live webcam self-view from launch with recording handoff

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: DockPanel + DockView (idle state) + menu-bar demotion

**Files:**
- Create: `App/Dock/DockPanel.swift`, `App/Dock/DockView.swift`
- Modify: `App/AppModel.swift` (dock lifecycle + per-source start flows)
- Modify: `App/OpenCharmApp.swift` (MenuBarExtra → `.menu` style)
- Delete: `App/Recorder/RecorderPanelView.swift`

**Interfaces:**
- Consumes: `AppModel` (engine, sources, `isCountingDown`, `lastError`, `missingPermissions`, `beginCountdownAndRecord()`, `openProjectPanel()`, `setCameraEnabled/setMicEnabled`, `refreshIdlePreview`), `OnboardingView(model:)`, `AreaSelectorWindow.present(onSelect:)`, `SourcePickerModel` (mode/displays/windows/devices/fps/systemAudio).
- Produces (Task 4 extends): `DockView` with an `idleDock` body switched on `engine.state` (Task 4 fills `.recording`/`.stopping` branches — leave a `recordingPlaceholder` view Task 4 replaces); `AppModel.showDock()/hideDock()`; `AppModel.startDisplayRecording(_ id: CGDirectDisplayID)`, `startWindowRecording(_ w: SCWindow)`, `startAreaRecording()`.

- [ ] **Step 1: DockPanel**

`App/Dock/DockPanel.swift`:
```swift
import AppKit
import SwiftUI

/// Floating, nonactivating, draggable dock chrome. Content is SwiftUI (DockView).
/// Position persists across launches via UserDefaults.
final class DockPanel: NSPanel, NSWindowDelegate {
    private static let originKey = "DockPanelOrigin"

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        delegate = self

        let host = NSHostingView(rootView: content)
        // Resize the panel whenever the SwiftUI content's ideal size changes —
        // this is what shrinks the dock into the stop bar and back.
        host.sizingOptions = [.preferredContentSize]
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 120)
        contentView = host
        setContentSize(host.fittingSize)

        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2,
                                   y: f.minY + f.height * 0.18))
        }
    }

    // Popovers and buttons inside need key status; nonactivating panels may refuse it
    // by default for borderless masks.
    override var canBecomeKey: Bool { true }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }
}
```

- [ ] **Step 2: DockView (idle)**

`App/Dock/DockView.swift`:
```swift
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
            case .recording, .stopping:
                recordingPlaceholder // Task 4 replaces this with the stop bar
            case .idle:
                idleDock
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.82)))
        .fixedSize()
    }

    var recordingPlaceholder: some View {
        Text("Recording…").foregroundStyle(.white)
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
                toggleButton(on: "mic", off: "mic.slash", label: "Mic",
                             isOn: sources.micEnabled) {
                    model.setMicEnabled(!sources.micEnabled)
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
```

- [ ] **Step 3: AppModel dock lifecycle + per-source flows**

In `App/AppModel.swift`:
1. Add:
```swift
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
```
(`import ScreenCaptureKit` if `SCWindow` isn't already resolvable in this file.)
2. Delete `beginAreaSelection()` (superseded; nothing else calls it once RecorderPanelView is gone).
3. In `launchUI()` (Task 2), add `showDock()` as the first line.

- [ ] **Step 4: Menu bar → plain menu; delete the panel**

`App/OpenCharmApp.swift` — replace the entire `MenuBarExtra` scene with:
```swift
        MenuBarExtra {
            Button("Show Dock") { model.showDock() }
            Button("Open Project…") { model.openProjectPanel() }
                .keyboardShortcut("o")
            Divider()
            Button("Quit OpenCharm") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.engine.state == .idle
                  ? "record.circle" : "record.circle.fill")
        }
```
(no `.menuBarExtraStyle` modifier — `.menu` is the default). Delete `App/Recorder/RecorderPanelView.swift` (`git rm`). `OnboardingView` stays (used by the dock's permission popover) — verify it doesn't reference `RecorderPanelView`.

- [ ] **Step 5: Build + visual check**

`make build` → BUILD SUCCEEDED. Launch; wait 3 s; `screencapture -x /tmp/dock-check.png`; Read the PNG and verify: dock visible with title "What to record?", the 7 items in order (✕, Display, Window, Area, Camera, Mic, System Audio), toggles rendered filled (all default on), webcam bubble also present. Then drag-persistence check without clicking: `pkill OpenCharm`, relaunch, screenshot again — dock must reappear at the same position. `make test` green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(app): floating recorder dock replaces the menu-bar panel

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Recording morph, context menus, fps, docs

**Files:**
- Modify: `App/Dock/DockView.swift` (recording/stopping states, context menus)
- Modify: `docs/SMOKE.md`, `README.md`

**Interfaces:**
- Consumes: everything from Task 3; `RecordingEngine.State.recording(startedAt: Date)`; `AppModel.stopRecording()`; `sources.fps`, `sources.cameras`, `sources.mics`, `cameraID`, `micID`; `model.refreshIdlePreview()`; `model.openProjectPanel()`.
- Produces: final DockView; updated docs. End of feature.

- [ ] **Step 1: Recording + stopping states**

In `App/Dock/DockView.swift`, replace `recordingPlaceholder` and the `body` switch:
```swift
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
```
and add:
```swift
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
```
Note: the dock panel auto-sizes via `fixedSize()` + hosting-view fitting; the morph shrinks the panel naturally.

- [ ] **Step 2: Context menus (device pickers, fps, app menu)**

Still in `DockView.swift`:
1. On the Camera toggle button add:
```swift
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
```
2. On the Mic toggle button, the same pattern over `sources.mics` setting `sources.micID` (no `refreshIdlePreview` call — there is no idle mic session).
3. On the outermost dock background (the `.background(...)` view in `body`), add:
```swift
        .contextMenu {
            Picker("Frame rate", selection: $sources.fps) {
                Text("60 fps").tag(60)
                Text("30 fps").tag(30)
            }
            Divider()
            Button("Open Project…") { model.openProjectPanel() }
            Button("Quit OpenCharm") { NSApp.terminate(nil) }
        }
```

- [ ] **Step 3: Docs**

`docs/SMOKE.md` — replace items that referenced the menu-bar panel with dock equivalents and add new ones; the list becomes:
```markdown
# Manual smoke checklist (run before each release)

Capture cannot run on CI — walk this list on real hardware.

1. Fresh permissions: revoke all three in System Settings, launch. Dock appears;
   clicking any source opens the permission popover; deep links land on the right
   pane; after granting, sources start normally.
2. Launch: dock + live webcam bubble appear with no clicks. Camera toggle off →
   bubble hides AND camera light turns off; on → live again. Right-click Camera/Mic
   to switch devices.
3. Display + camera + mic + system audio, 60 fps, 10 s with music and speech:
   click Display → countdown → dock morphs to timer + Stop; tracks exist, styled
   preview opens on stop, mic/system audible, no drift.
4. Window mode on a Safari window; Area mode on a ~800×600 region (drag →
   countdown starts immediately): exported dimensions match (even-rounded).
5. Neither the dock, the stop bar, nor the bubble appear anywhere in any
   recording; bubble draggable while recording; dock draggable always, and its
   position persists across relaunch.
6. ✕ hides the dock; menu bar → Show Dock brings it back. Open Project… (menu,
   ⌘O, and dock right-click) opens a chosen .opencharm; bad selection shows an
   error alert.
7. Noise removal toggle: audible hiss reduction; second toggle instant (cache).
8. Export Source/1080p/4K in both codecs; files play in QuickTime; Reveal in
   Finder works.
9. Kill the app (Force Quit) 5 s into a recording. Relaunch: recovery prompt at
   launch; recovered project opens in the Studio and plays up to ~2 s before the
   kill.
10. Unplug an external webcam mid-recording: recording continues; stop succeeds;
    idle preview resumes on the remaining camera (or hides bubble if none).
```
`README.md` — in Build and Run, replace the menu-bar-app paragraph: the app now opens a floating "What to record?" dock plus a live webcam bubble at launch (menu bar icon remains for Show Dock / Open Project / Quit). Keep the rest.

- [ ] **Step 4: Build + visual checks**

`make build` → BUILD SUCCEEDED. Launch; screenshot the idle dock (Read it: toggles + title correct). `make test` green. Interactive checks (recording morph, context menus) defer to user smoke — list them in the report.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(app): dock recording morph, device/fps context menus, smoke docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Plan Self-Review Notes (already applied)

- **Spec coverage**: dock window/persistence/✕ (T3), click-to-go flows incl. multi-display popover (T3), toggles + slashed icons + right-click device pickers (T3/T4), permission popover (T3), error strip (T3), recording morph + timer + stop + stopping spinner (T4), countdown disable (T3 `.disabled(model.isCountingDown)`), webcam-at-launch + handoff + toggle/light behavior (T2), Studio→AppKit + workaround deletion (T1), menu-bar demotion + ⌘O restoration (T3), fps context menu (T4), SMOKE/README (T4). Idle-session failure degradation covered in `startIdlePreview` (bubble hidden, non-fatal); toggle badge on denial simplified to hidden bubble + permission popover on source click — matches spec's error-handling intent without a new badge component.
- **Type consistency**: `openStudio(_:)` (T1) used by T3 menu (`openProjectPanel` internally); `setCameraEnabled/setMicEnabled/refreshIdlePreview` (T2) used by T3/T4; `startDisplayRecording/startWindowRecording/startAreaRecording` (T3) used by DockView (T3).
- **Known risks flagged for implementers**: SwiftUI `.popover`/`.contextMenu` inside a nonactivating borderless NSPanel (canBecomeKey=true is the mitigation; if popovers refuse to present, fall back to NSMenu via NSHostingMenu or report); `MenuBarExtra` label observing `model.engine.state` continues to work via the existing objectWillChange forwarding; the T1 recovery-fixture check kills a run-loop-blocked app by design.
