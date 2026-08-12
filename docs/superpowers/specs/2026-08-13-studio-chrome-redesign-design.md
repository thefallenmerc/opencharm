# Studio Chrome Redesign — Design Spec

**Date:** 2026-08-13
**Status:** Approved (brainstormed + amended with Screen Charm archive analysis)
**Reference:** Screen Charm editor screenshot; `.screencharm` project archive analysis (below)

## Goal

Rebuild the OpenCharm Studio editor as a clean-slate, dark, mac-worthy chrome that
replicates the Screen Charm editor layout — icon rail, styled inspector panels, custom
toolbar, elegant transport + timeline — and implement the engine features those controls
need (aspect-ratio presets, playback speed, camera layout presets, background blur), plus
a smooth, shake-free zoom engine and full undo/redo.

`StylingModel` remains the spine; the *view layer* is clean-slate. Working gesture code
(webcam drag/resize, trim caps, two-click zoom creation, pill drag/resize anchors) is
ported, not rewritten.

## 1. Architecture (new `App/Studio/` view hierarchy)

- **`StudioTheme.swift`** — design tokens: near-black window `#0D0D10`, raised panel
  `#1A1A1E`, chip `#232328`, indigo accent (Export/selection), existing purple video
  gradient + gold zoom gradient; type scale; reusable `ChipButtonStyle`, segmented chips,
  preset-thumbnail card, section header.
- **`StudioRootView.swift`** — chrome: toolbar strip, then
  `HStack { icon rail | inspector panel | canvas + transport + timeline }`. Window uses
  `fullSizeContentView` + transparent titlebar; traffic lights overlay the dark chrome.
- **`StudioToolbar.swift`** — centered project name with faded extension + "Edited" dot;
  left cluster (open, undo, redo, help); right cluster ("New recording" chip, accent
  "Export"). Save stays ⌘S + existing close-prompt flow.
- **`SidebarRail.swift`** — 4 sections: General, Cursor, Sound, Camera (no
  Shared/Affiliate/Frames).
- **`Panels/`** — one scrollable dark panel per rail item:
  - *General*: Camera Layout presets, Aspect Ratio, Background (Image/Gradient/Color tabs,
    thumbnail grid, blur slider, Upload custom), Playback Speed, Zoom Level, Padding,
    corner radius, shadow.
  - *Cursor*: synthetic cursor size (existing).
  - *Sound*: noise removal, voice enhance, mic/system volume (existing).
  - *Camera*: show webcam, layout preset, corner position, size %, roundness,
    content zoom.
- **`StudioCanvas.swift`** — preview centered on the dark stage, rounded; ports
  `WebcamDragOverlay` + resize handles verbatim.
- **`StudioTransport.swift` + timeline** — ported logic, restyled: transport centered
  (current time · ⏮ ▶ ⏭ · duration), timeline-zoom slider + % left, Cut chip right,
  floating "To end" chip, tighter ruler, softer radii, purple track + gold pills kept.

Old `StylingView`/`InspectorView`/`StudioTimeline` views are deleted once the new chrome
is wired into `StudioWindowController`.

## 2. Engine features (additive `RenderSettings` fields; old projects decode fine)

- **Aspect ratio** — `aspectPreset: auto | 16:9 | 4:3 | 1:1 | 9:16`. `CanvasLayout`
  sizes the canvas per preset (auto = screen aspect + padding); screen content
  letterboxed/padded; preview and export both honor it.
- **Playback speed** — `playbackSpeed` (0.5–2). Preview via `AVPlayer.rate`; export via
  `scaleTimeRange` on the composition (audio pitch-preserved). Persisted globally now;
  Screen Charm's per-interval `{start, end, playbackSpeed}` model is the noted follow-on
  for multi-cut support.
- **Camera layout presets** — thumbnail row writing `WebcamSettings` (corner
  positions/sizes, hidden); plus `contentZoom` (crop-zoom inside the bubble). No
  compositor layout changes needed beyond content zoom.
- **Zoom level** — sets `autoZoom.level` and default scale for new manual pills
  (Screen Charm default: 2×).
- **Backgrounds** — bundle a small set of macOS-style wallpapers, plus gradient/color
  preset tabs (SwiftUI-rendered thumbnails) and custom image upload; new
  `backgroundBlur` setting applied in the compositor.
- **Undo/redo** — snapshot-based on `StylingModel`: one undo record per discrete change
  of `(renderSettings, zooms, audioSettings, trim)`; slider drags coalesced (snapshot at
  drag start); wired to the window `NSUndoManager` → ⌘Z/⇧⌘Z + toolbar arrows.

## 3. Smooth, shake-free zoom (informed by archive analysis)

Screen Charm's baked curves show a **critically damped spring settle** (slow quadratic
start, exponential tail, zero overshoot; ~0.8 s settle) and **low-pass-filtered cursor
following** for pan (coefficient ≈ 0.2), with pan frozen during ease-in/out and explicit
holds (≈1.1 s after zoom-in before following; ≈1.3 s idle before zoom-out).

Implementation in `AutoZoom`/`Compositor` (deterministic closed-form so preview == export,
and unit-testable):

- Scale envelope: critically damped spring toward the target level, ~0.8 s settle,
  scaled by the user `speed` knob.
- Pan: focus path run through a one-pole low-pass filter of the click/drag positions;
  frozen while easing; clamped so the viewport never crosses the screen edge. The filter
  inherently swallows micro-jitter (no separate deadband needed).
- Holds: ~1.1 s post-zoom-in before panning; ~1.3 s idle before ease-out (existing
  chainGap/postClickHold constants retuned to match).

Out of scope: cursor-move + cursor-type tracking during recording (Screen Charm records
per-frame moves and pointer type; we record clicks only — pan follows click/drag
positions). Intro/outro text cards.

## 4. Testing & verification

- Unit tests: canvas math per aspect preset; retiming duration math; spring envelope
  monotonic, zero-overshoot, endpoint-smooth; low-pass pan filter convergence + edge
  clamping; undo snapshot round-trip.
- Existing RenderCore golden/layout tests updated where canvas math changed.
- Manual smoke pass per `docs/SMOKE.md` (record → edit every new control → export),
  additions documented in that file.

## Appendix: `.screencharm` archive findings (2026-08-13)

A `.screencharm` project is a plain directory: `recording.mp4` (60 fps retina),
`webcam.mp4`, `microphone.wav` (+`microphone_enhanced.wav`),
`recording.input-events.json` (frame-indexed moves + clicks with cursorType),
`record-info.json` (capture geometry), `project.json` (metadata + editorSettings),
`playerProps.json` (full editor state with baked per-frame animation).

Key values observed: `zoomDurationSec 0.8`, `zoomInFreezeDurationSec 1.1`,
`zoomOutFreezeDurationSec 1.3`, `cursorSpeed 0.2`, `defaultZoomInLevel 2`,
`intervals [{start, end, playbackSpeed}]`, `cameraPosition 'left-bottom'`,
`cameraSize 23`, `cameraContentZoom 1`, `cursorSize 3` (synthetic cursor multiplier),
`backgroundImageBlur`, `shadowIntensity`, wallpaper backgrounds
(`15-Sequoia-Light.jpeg`, `26-Tahoe-Light-6K-thumb.jpeg`). Zoom `scales` sample
(level 2, 48 frames): 0 → .014 → .077 → .266 → .564 → .738 → .838 → .902 → .944 → .971
→ .988 → 1; per-frame `framesData` bakes
`[panX, panY, scale, cursorX, cursorY, cursorSize, camW, camH, cursorType]`.
