# OpenCharm — Floating Recorder Dock Design

**Date:** 2026-08-02
**Status:** Approved
**Supersedes:** the menu-bar recorder panel UI from the M1 design (recording pipeline, Studio window content, and all packages are unchanged).

## Goal

Replace the menu-bar recorder panel with a Screen Charm-style floating, draggable dock that appears as soon as the app launches, with a live webcam self-view starting immediately. Reference: user-provided screenshot — dark rounded palette titled "What to record?" with `✕ | Display | Window | Area ‖ Camera | Mic | System Audio`.

## Decisions (user-approved)

| Decision | Choice |
|---|---|
| Start flow | Click-source-to-go: clicking Display/Window/Area proceeds straight to (chooser →) countdown → record; no Record button |
| During recording | Dock morphs into a compact draggable stop bar (red dot + elapsed timer + Stop); returns to full dock on stop |
| ✕ button | Hides the dock; a plain menu-bar menu (Show Dock / Open Project… ⌘O / Quit) remains as the way back |
| Webcam at launch | Always on: live bubble appears at app open (permission prompt on first launch); Camera toggle hides bubble + disables webcam track |
| Implementation vehicle | Nonactivating floating `NSPanel` hosting SwiftUI content (never steals focus); menu bar becomes `.menu`-style |

## Dock window (`DockPanel`)

- Borderless, nonactivating `NSPanel`; `level = .floating`; `isMovableByWindowBackground = true`; `isReleasedWhenClosed = false`; hidden-from-Mission-Control collection behavior.
- Dark rounded-material background (matches reference); content is SwiftUI `DockView` via `NSHostingView`.
- Shown at launch. Frame origin persisted (UserDefaults) and restored; first launch centers it in the lower third of the main screen.
- Excluded from recordings automatically (existing app-level `SCContentFilter` exclusion).
- `✕` orders the panel out (app keeps running). Menu bar → Show Dock re-shows it.

## DockView states

Driven by existing `AppModel`/`RecordingEngine.state` (the `objectWillChange` forwarding already exists).

**Idle** — title "What to record?"; one row:
- `✕` (hide dock)
- **Display**: single display → `beginCountdownAndRecord()` immediately; multiple displays → small anchored popover listing displays, pick → countdown.
- **Window**: anchored popover with the window list (reuses `SourcePickerModel.windows`), pick → countdown.
- **Area**: existing `AreaSelectorWindow` flow → on selection → countdown. (Re-select each time; no sticky area chip in the dock.)
- Divider.
- **Camera / Mic / System Audio** toggles: filled icon = on, slashed icon = off (SF Symbols `video`/`video.slash`, `mic`/`mic.slash`, `speaker.wave.2`/`speaker.slash`). Left-click toggles. Right-click Camera/Mic → device-picker context menu (lists from `SourcePickerModel`, checkmark on current).
- Right-click dock background → context menu: Frame rate 60/30, Open Project…, Quit.
- Source clicks while required permissions are missing → anchored popover embedding the existing onboarding rows (grant buttons + Settings deep links) instead of starting.
- During countdown (`isCountingDown`) all controls disabled.

**Recording** — compact bar replacing the row: red recording dot, elapsed time `mm:ss` (driven by `RecordingEngine.state.recording(startedAt:)`), **Stop** button → existing `stopRecording()` flow (Studio opens as today). **Stopping** — bar shows a spinner, Stop disabled.

**Error surface** — `lastError` shows as a transient one-line strip beneath the dock row, auto-dismissing after ~5 s (replaces the panel's inline error text). Open-project errors keep their NSAlert.

## Webcam preview at launch (`CameraPreviewController`)

- App-layer object owning an idle `AVCaptureSession` (selected camera device, no outputs, preview layer only) plus the existing `SelfViewWindow` bubble.
- On launch: request camera permission if undetermined → start idle session → show bubble (same default position/drag behavior as today).
- Camera toggle OFF: stop session (camera light off), hide bubble, `webcamDeviceID = nil`. ON: restart, re-show.
- Right-click device switch restarts the idle session on the new device.
- **Recording handoff**: before `engine.start`, stop the idle session (releases the device); after start, swap the bubble's layer to `engine.webcamPreviewLayer` (existing plumbing). On stop/failure rollback, resume the idle session and swap back. A sub-second preview gap during handoff is accepted. The Recording package is not modified.
- Mic/System Audio toggles map to `micDeviceID`/`capturesSystemAudio` exactly as the panel did; no idle mic session exists (no meter in this iteration).

## Studio window → AppKit (`StudioWindowController`)

- `NSWindowController` owning a titled, closable, resizable NSWindow (min 480×320, default 1100×700, `isReleasedWhenClosed = false`) hosting the existing styling content view; per-project `StylingModel` reuse (the `StylingModelCache` behavior) moves inside the controller.
- `AppModel.openStudio(package:)` becomes a plain method: used by stop-flow, launch recovery, and Open Project — the SwiftUI `Window` scene, `openStylingWindow` closure, and `pendingStylingOpen` flag are all deleted.
- Export sheet and all Studio content are unchanged.

## Menu bar

`MenuBarExtra` switches to `.menu` style: **Show Dock**, **Open Project…** (⌘O), **Quit**. The recorder panel (`RecorderPanelView`) and its onboarding embedding are retired; onboarding row views are reused by the dock's permission popover. The icon still reflects recording state (filled while recording).

## App lifecycle summary

Launch → AppDelegate (existing) runs recovery check → dock appears + webcam bubble live. Record: dock click → (chooser/area) → countdown → dock morphs to stop bar → Stop → Studio opens over everything (`NSApp.activate`). ✕/menu control dock visibility. Quit from menu or dock context menu.

## Error handling

- Camera permission denied at launch: bubble not shown; Camera toggle shows off+warning badge; clicking it opens the permission popover. App otherwise fully functional.
- Idle-session start failure (device busy/vanished): bubble hidden, toggle badged, non-fatal.
- Recording start failure: existing rollback (Task 15 fix) plus idle-preview resume.
- Engine state changes continue to drive all UI via the existing publisher forwarding.

## Testing

- No headless UI harness exists for the App layer (unchanged constraint): verification is `make build`, launch checks, and an updated `docs/SMOKE.md` (dock replaces menu-bar-panel items; add: dock draggable + position persists across relaunch; webcam bubble live at launch; camera toggle stops the camera light; dock/stop bar never appear in recordings; ✕ + Show Dock round-trip).
- All package suites must stay green (`make test`) — no package code changes are expected; any needed package change is a red flag to re-review.

## Out of scope (YAGNI)

Pause, vertical dock orientation, global hotkeys, per-display docks, mic level meter, sticky area selection, dock opacity/appearance settings.
