# OpenCharm — Milestone 1 Design

**Date:** 2026-08-01
**Status:** Approved
**Product:** OpenCharm — an open-source macOS screen recorder in the spirit of Screen Charm (screencharm.com), producing polished, styled recordings with a webcam overlay and cleaned-up audio.

## Decisions locked during brainstorming

| Decision | Choice |
|---|---|
| Stack | Native Swift + SwiftUI (ScreenCaptureKit, AVFoundation, Core Image/Metal, AVAudioEngine) |
| Milestone slicing | Recorder-first: M1 = record → styled export; M2 = timeline editor; M3 = polish effects |
| Architecture | Raw tracks recorded separately, composited non-destructively at preview/export time |
| Distribution | GitHub Releases (notarized DMG later, Homebrew cask later), macOS 14 (Sonoma)+ |
| Name / bundle ID | OpenCharm / `com.thefallenmerc.OpenCharm` |
| License | GPL-3.0 (compatible with BSD-licensed RNNoise) |
| Build tooling | XcodeGen (`project.yml` committed, `.xcodeproj` generated), local SPM packages, SwiftFormat, GitHub Actions CI |

## Goal of Milestone 1

A user can record their screen (full screen, one window, or a selected area) together with webcam, microphone, and system audio; then, in a styling window with a live preview, wrap the recording in a pretty canvas (background, padding, rounded corners, shadow), position a rounded webcam bubble, toggle noise removal and voice enhancement, and export an MP4 up to 4K. Every recording is a reopenable project — styling is never baked in.

Out of scope for M1 (deferred): trim/cut/split, speed control, zoom effects, motion blur, cursor re-rendering/smoothing/click ripples, background music, social canvas presets, cloud sharing. M1 *does* record the cursor/click event stream so M3 features work retroactively on M1 recordings.

## User experience

### Recorder

1. OpenCharm is a menu bar app. Clicking the icon opens a compact recorder panel:
   - Capture source: **Full screen** (display picker if multiple) · **Window** (native macOS picker) · **Area** (draggable/resizable selection rectangle overlay)
   - **Webcam**: device picker + on/off
   - **Microphone**: device picker + on/off
   - **System audio**: on/off
2. Start → 3-2-1 countdown overlay → recording begins.
3. While recording: a small floating webcam **self-view bubble** (excluded from the screen capture via the ScreenCaptureKit content filter, so it never appears in the recording) and a stop control in the menu bar.
4. Cursor positions and mouse click events are logged with host-clock timestamps to `events.jsonl` throughout the recording.
5. Stop → tracks finalize → the styling window opens automatically.

### Styling window

Live composited preview (play/pause/scrub) plus an inspector:

- **Canvas**: background — solid color / gradient presets / bundled image presets / user-chosen image file; inner padding; corner radius of the screen recording; shadow depth. In M1 the canvas keeps the recording's aspect ratio (social aspect presets are M3).
- **Webcam bubble**: position — four corner presets or free drag on the preview; size; shape morph from circle to rounded rectangle; hide.
- **Audio**: noise removal toggle (RNNoise); voice enhance toggle (EQ + compression); mic volume; system audio volume. When the styling window opens, processed variants of the audio tracks are rendered once in the background and cached inside the package (`cache/`, regenerable), so the toggles switch what you hear in preview instantly.
- **Export**: MP4 container; H.264 or HEVC; resolution: Source (canvas at the recording's native pixel size) / 1080p / 4K, fitted to the canvas aspect; progress bar; "Reveal in Finder" on completion.

### Projects

- Every recording is auto-saved as a `.opencharm` package under `~/Movies/OpenCharm/`, named by timestamp and renameable.
- Reopening a project restores the styling window with saved settings; re-export any time. Raw tracks are never modified.

## Architecture

Five modules — local Swift packages consumed by one app target:

| Module | Purpose | Key APIs |
|---|---|---|
| `Recording` | Capture all sources to disk as separate synced tracks | ScreenCaptureKit (screen + system audio), AVCaptureSession (webcam), AVAudioEngine (mic), AVAssetWriter per track |
| `ProjectStore` | Read/write `.opencharm` packages; versioned `project.json` schema with migrations | Codable, FileWrapper |
| `RenderCore` | The compositor: `(RenderSettings, time, input frames) → output frame`. Single render path shared by live preview and export | Core Image + Metal, custom `AVVideoCompositing` |
| `AudioPipeline` | Offline denoise (RNNoise wrapped as an SPM C target), voice enhance (EQ + compressor), mix mic + system audio | AVAudioEngine offline rendering |
| `App` | SwiftUI UI: menu bar item, recorder panel, area-selector overlay window, countdown overlay, self-view bubble window, styling window, export sheet, onboarding | SwiftUI + AppKit where needed |

Module isolation rules: `RenderCore` and `AudioPipeline` know nothing about files or UI — they operate on buffers and settings values, which is what makes them golden-testable. `ProjectStore` knows nothing about rendering. `Recording` produces files + offsets and hands off; it never renders.

### Track synchronization

ScreenCaptureKit and AVCapture both deliver `CMSampleBuffer`s stamped against the host clock (`CMClockGetHostTimeClock`); the mic tap timestamps are converted to the same clock. Each track records its first-buffer host timestamp; `project.json` stores per-track start offsets relative to the earliest track. The compositor aligns by timestamp, not frame index, so differing frame rates (e.g. 60 fps screen, 30 fps webcam) stay in sync with no drift.

### Crash safety

All `AVAssetWriter`s write fragmented movies (`movieFragmentInterval` ≈ 2 s), so a crash or force-quit loses at most the final fragment. A sentinel file in the package marks "recording in progress"; on next launch, if a sentinel is found, OpenCharm offers **Recover recording**, finalizes what exists, and opens the styling window.

### Capture formats

- **Screen**: 60 fps default (30 fps selectable), HEVC hardware encode at high bitrate (visually lossless at capture resolution, including Retina 2x backing scale).
- **Webcam**: HEVC at the device's native resolution.
- **Mic and system audio**: uncompressed PCM in `.caf` — denoising quality is much better on unprocessed audio, and PCM at recording lengths is cheap.
- **Cursor**: rendered into the screen capture by ScreenCaptureKit in M1 (simple and correct); positions/clicks additionally logged to `events.jsonl` (JSON Lines: `{t, x, y, type}`) for M3 auto-zoom/cursor effects. Mouse events come from a global `NSEvent` monitor (no accessibility permission required for mouse events).

### Project package format

```
MyRecording.opencharm/
  project.json     # schemaVersion, track list + start offsets, style + audio settings
  screen.mov
  webcam.mov       # absent if webcam was off
  mic.caf          # absent if mic was off
  system.caf       # absent if system audio was off
  events.jsonl     # cursor/click stream
  cache/           # regenerable processed-audio variants for instant preview
  recording.lock   # sentinel, present only while recording (crash detection)
```

`project.json` carries a `schemaVersion`; `ProjectStore` migrates older versions forward on open. v1 files must open in every future version.

### Export

`AVAssetWriter` session driven by `RenderCore` (same compositor as preview) for video and `AudioPipeline`'s offline-rendered mix for audio → MP4. Export never mutates the project package; a failed export deletes its partial output file and leaves the project untouched.

## Permissions

Three TCC permissions: Screen Recording, Camera, Microphone. First-run onboarding shows per-permission status with a button deep-linking to the exact System Settings pane. Recording is blocked with clear messaging (never crashes) until the required permissions for the chosen sources are granted. System audio capture rides on the Screen Recording permission via ScreenCaptureKit.

## Error handling

| Failure | Behavior |
|---|---|
| Permission denied | Onboarding/status UI with System Settings deep link; start button disabled with reason |
| Webcam unplugged mid-recording | Screen/audio continue; webcam track finalized at disconnect; bubble simply ends at that point in preview |
| Mic device disappears | Same pattern: remaining tracks continue, mic track finalized |
| Low disk space | Pre-flight estimate (resolution × bitrate × safety factor) refuses to start below threshold; warning surfaced if space runs low mid-recording |
| Crash / force-quit mid-recording | Fragmented tracks survive; sentinel triggers "Recover recording" on next launch |
| Export failure | Partial output deleted; clear error; project untouched and re-exportable |

## Testing

- **ProjectStore**: round-trip encode/decode unit tests; schema-migration tests pinned against committed v1 fixture files.
- **RenderCore**: golden-image tests — synthetic input frames rendered with fixed settings, compared against committed reference PNGs (pins the padding/corner/shadow/bubble math).
- **AudioPipeline**: fixture WAVs (voice + injected hiss/keyboard noise) processed; assert measured noise-floor reduction and absence of clipping.
- **Recording**: integration test records a few seconds of synthetic/screen content and asserts track start offsets align within one frame duration.
- **CI**: GitHub Actions macOS runner — `xcodegen`, build, unit tests on every push. Live capture cannot run headless; a documented manual smoke checklist covers it per release.

## Repository layout

```
opencharm/
  project.yml            # XcodeGen; .xcodeproj is generated, not committed
  App/                   # SwiftUI app target sources + assets + Info.plist entries
  Packages/
    Recording/
    ProjectStore/
    RenderCore/
    AudioPipeline/
  Tests/                 # per-package tests + golden/audio fixtures
  docs/
    superpowers/specs/   # this document and future specs
  .github/workflows/ci.yml
  LICENSE                # GPL-3.0
  README.md
  Makefile               # make gen / build / test / format
```

## Future milestones (outline, not designed yet)

- **M2 — Editor**: timeline model over the same `.opencharm` packages; trim/cut/split; per-clip speed; manual zoom keyframes; auto-zoom candidates derived from `events.jsonl` clicks.
- **M3 — Polish**: motion blur on zooms/cursor moves; cursor re-rendering (SCK cursor hidden, smoothed cursor drawn by RenderCore) with click ripples; background music with ducking; social canvas presets (16:9, 1:1, 9:16, etc.); optional shareable-link upload story.
