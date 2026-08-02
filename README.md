# OpenCharm

Open-source macOS screen recorder with polished output: screen + webcam + mic +
system audio, styled canvas (background, padding, rounded corners, shadow),
webcam bubble overlay, and one-toggle noise removal. GPL-3.0. macOS 14+.

An open alternative in the spirit of [Screen Charm](https://screencharm.com).

## Features (Milestone 1)

- **Record** full screen (with a display picker on multi-monitor setups), a
  single window, or a draggable/resizable area — together with webcam,
  microphone, and system audio, each captured as its own track. A 3-2-1
  countdown precedes every recording.
- **Self-view bubble**: a floating, draggable webcam preview shown while
  recording, excluded from the capture itself via the ScreenCaptureKit
  content filter — it never appears in the output.
- **Cursor/click event log**: every recording's mouse position and clicks are
  logged to `events.jsonl` with host-clock timestamps, for future auto-zoom
  and click-ripple effects.
- **Styling window** with a live composited preview: background (solid,
  gradient, or image), padding, corner radius, and shadow around the screen
  content; a repositionable, resizable webcam bubble with a
  circle-to-rounded-rectangle shape morph; noise removal (RNNoise) and voice
  enhancement toggles with instant-switch caching.
- **Export** to MP4 (H.264 or HEVC) at Source / 1080p / 4K resolution, with a
  progress sheet, cancellation, and "Reveal in Finder" on completion.
- **Projects**: every recording is saved as a reopenable `.opencharm`
  package under `~/Movies/OpenCharm/` — raw tracks are never modified, so
  styling settings can be changed and re-exported at any time. `⌘O` opens
  any past project.
- **Crash recovery**: if OpenCharm quits mid-recording, the next launch
  offers to recover the interrupted project (everything captured up to the
  last flushed moment) or discard it. A low-disk guard blocks starting a
  recording with under 2 GB free and warns if space runs low mid-recording.

Out of scope for M1 (planned for later milestones): trim/cut/split, speed
control, zoom effects, cursor smoothing/click ripples, background music,
social aspect-ratio presets, cloud sharing.

See [`docs/superpowers/specs/2026-08-01-opencharm-m1-design.md`](docs/superpowers/specs/2026-08-01-opencharm-m1-design.md)
for the full design spec and [`docs/superpowers/plans/2026-08-01-opencharm-m1.md`](docs/superpowers/plans/2026-08-01-opencharm-m1.md)
for the implementation plan. Before each release, walk
[`docs/SMOKE.md`](docs/SMOKE.md) — the capture-and-export paths can't run on
CI and need a manual pass on real hardware.

## Build

    brew install xcodegen swiftformat
    make build     # generates OpenCharm.xcodeproj and builds
    make test      # runs package unit tests

The first `make build`/`make gen`/`make test` downloads the ~74 MB RNNoise
noise-removal model from Xiph's servers (checksum-verified; see
`Tools/fetch-rnnoise-model.sh`) — it is not committed to the repo. Subsequent
runs skip the download once it's cached locally. Run `make fetch-model` to
fetch it on its own.

Open `OpenCharm.xcodeproj` (after `make gen`) to run from Xcode.
