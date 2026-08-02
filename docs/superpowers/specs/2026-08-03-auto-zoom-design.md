# OpenCharm — Auto-Zoom (smart zoom-on-click) Design

**Date:** 2026-08-03
**Status:** Approved

## Goal

A Screen Studio-style post-process effect: during playback and export, the screen content smoothly
zooms in toward where the user clicked, holds while activity stays there, glides between regions, and
eases back out. The webcam bubble and padded background stay fixed — only the **screen layer** zooms
and crops. Fully automatic (v1): a toggle plus two knobs (zoom level, speed); no per-segment editing.

The raw material already exists: `EventLogger` writes `events.jsonl` (mouse down/up/move, timestamps
rebased to the composition clock) into every project. It is currently orphaned — nothing reads it.

## Motion model

- **Hold-steady per region, glide between regions.** Clicks close in time AND space cluster into one
  zoom segment focused on the cluster centroid. Distinct regions become separate segments; between
  them the view eases out to 1× and into the next. (True direct panning between held zooms is a
  future enhancement.)
- Per segment: ease-in (~0.25–0.6 s) → hold → ease-out (~0.35–0.8 s), a smoothstep envelope. Focus is
  constant within a segment; only `scale` animates 1→level→1, which reads as zooming into the point.

## Data flow

```
events.jsonl ──(App: ClickTrack.load, map global→normalized via manifest.captureRect)──▶ [ClickEvent]
[ClickEvent] + settings.autoZoom ──(RenderCore: AutoZoom.segments, pure)──▶ [ZoomSegment]
[ZoomSegment] ──(CharmInstruction)──▶ CharmVideoCompositor.startRequest
  per frame: ZoomTimeline.state(at: compositionTime) ──▶ ZoomState{scale, focus}
  Compositor.render(..., zoom:) crops the screen layer, then places into contentRect (unchanged path)
```

Preview and export both go through `ProjectCompositionBuilder.build` + `CharmVideoCompositor`, so the
effect appears identically in the Studio preview and exports.

## Components

### RenderCore (pure, testable — the core of v1)
- `AutoZoomSettings { enabled: Bool=false, level: Double=2.0 (1.5…3), speed: Double=0.5 (0…1) }`,
  `Codable, Equatable, Sendable`, `.default`. Added as an **optional** `autoZoom: AutoZoomSettings?`
  on `RenderSettings` (additive → old manifests decode `nil`; consumers use `?? .default`).
- `ClickEvent { time: Double /*composition seconds*/, point: CGPoint /*normalized screen, top-left 0…1*/ }`.
- `ZoomSegment { start, end, easeIn, easeOut: Double; focus: CGPoint; scale: Double }`.
- `ZoomState { scale: Double; focus: CGPoint; static let identity }`.
- `AutoZoom.segments(clicks:, settings:) -> [ZoomSegment]` — cluster by time gap (~1.4 s) + spatial
  proximity (~0.22 normalized); focus = centroid; scale = `level`; ease durations from `speed`; hold
  until last click + tail; resolve overlaps by capping to the next segment's start.
- `ZoomTimeline.state(at:segments:) -> ZoomState` — active segment + smoothstep envelope.
- `Compositor.render(_:settings:canvasSize:zoom:)` — new `zoom: ZoomState = .identity`. When
  `scale > 1`, crop `inputs.screen` to a `1/scale` window centered on `focus` (converted to CIImage
  y-up), clamped inside the image (no empty edges), then run the existing `place(...)` into
  `contentRect`. Crop preserves aspect, so `CanvasLayout` is unchanged. At `scale == 1` → byte-identical
  to today.
- `CharmInstruction` carries `segments: [ZoomSegment]`; `CharmVideoCompositor.startRequest` evaluates
  `ZoomTimeline.state(at: request.compositionTime.seconds, ...)` and passes it to `render`. The
  `HeldFrameCache` still caches the raw (uncropped) screen frame.
- `ProjectCompositionBuilder.build(..., clicks: [ClickEvent] = [])` computes
  `AutoZoom.segments(clicks:, settings: settings.autoZoom ?? .default)` and puts them on the instruction.

### ProjectStore
- `ProjectManifest.captureRect: CGRect?` (optional, additive; global desktop points, top-left origin) —
  the region the screen video covers, used to map global click coords → normalized. `nil` ⇒ no zoom
  (old projects, window capture). Migrator unchanged (optional decodes as `nil`; schemaVersion stays 1).

### Recording
- `RecordingEngine` computes the global capture rect from `configuration.source` and writes it to
  `manifest.captureRect` in `writeOffsetsIfComplete`:
  - `.display(id)` → `CGDisplayBounds(id)`.
  - `.area(displayID, rect)` → `CGDisplayBounds(displayID).origin + rect`.
  - `.window` → `nil` (window can move mid-recording; auto-zoom disabled for window captures).

### App
- `ClickTrack.load(package:) -> [ClickEvent]` — decode `events.jsonl` (`LoggedEvent` from Recording),
  keep `type == "down"`, map `(x,y)` via `manifest.captureRect` to normalized [0,1], drop out-of-bounds.
  Returns `[]` when `captureRect == nil`.
- `StylingModel` loads clicks once and threads them into both `ProjectCompositionBuilder.build` calls
  (`rebuildComposition`, `rebuildVideoComposition`) and into `ProjectExporter`.
- `ProjectExporter.init(..., clicks:)` → passes to `build`.
- `InspectorView` gains an **"Auto Zoom"** section: a toggle + **Zoom level** and **Speed** sliders,
  bound via nil-coalescing bindings on `renderSettings.autoZoom`. Existing 100 ms-debounced rebuild
  flows the change to the live preview; 500 ms persist writes it to the manifest.

## Testing
- Pure unit tests (RenderCore): `AutoZoom.segments` clustering/timing/overlap; `ZoomTimeline.state`
  envelope + interpolation; `Compositor` crop geometry (a mid-zoom frame crops toward focus; `scale==1`
  is a no-op).
- ProjectStore: `captureRect` round-trips; old (v1, no key) manifests still decode.
- App-layer click mapping verified by a small unit on `ClickTrack` if feasible, else covered by the
  RenderCore math tests + manual smoke.

## v1 non-goals
Per-segment timeline editing; keyboard/scroll-triggered zooms (only mouse is recorded); direct
region-to-region panning without easing through 1×; window-capture support.

## Verification
`make build` + `make test` (RenderCore/ProjectStore/Recording suites green; screen-capture duration
test is the known static-desktop flake — retry with screen activity). Manual smoke: record a
full-screen clip clicking around, open Studio, enable Auto Zoom → preview zooms toward clicks; export
matches; toggling off returns to a static frame.
