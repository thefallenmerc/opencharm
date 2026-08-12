# Studio Chrome Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild OpenCharm Studio as a dark, Screen-Charm-style editor (icon rail, styled panels, custom toolbar, elegant transport/timeline) with working aspect-ratio, playback-speed, camera-layout, background-blur features, spring-smooth shake-free zoom, and undo/redo.

**Architecture:** `StylingModel` stays the spine; the view layer is clean-slate under `App/Studio/`. Engine features are additive `RenderSettings` fields implemented in the RenderCore package (TDD). Old views (`StylingView`, `InspectorView`, `StudioTimeline`) are deleted at the end after the new chrome is wired in.

**Tech Stack:** Swift 5.9+, SwiftUI + AppKit (NSWindow chrome), AVFoundation, Core Image, XCTest via `swift test` per package, `xcodegen` + `xcodebuild` for the app.

## Global Constraints

- macOS deployment target **14.0** (from `project.yml`) — `player.defaultRate` is available.
- All new `RenderSettings`/`WebcamSettings` fields must be **optional (additive)** so old manifests/`.charmproj` archives decode.
- Preview and export must use the **same deterministic evaluation** (closed-form math in `ZoomTimeline`; no `Date`/randomness).
- Build app: `make build` (runs xcodegen). Test packages: `make test` or `swift test --package-path Packages/RenderCore`.
- Commit after every task. Spec: `docs/superpowers/specs/2026-08-13-studio-chrome-redesign-design.md`.
- Screen Charm reference values: zoom settle ≈ 0.8 s, pan low-pass τ ≈ 0.35 s, hold-before-zoom-out ≈ 1.3 s, default zoom level 2×.

---

### Task 1: AspectPreset + canvas sizing (RenderCore)

**Files:**
- Modify: `Packages/RenderCore/Sources/RenderCore/RenderSettings.swift`
- Test: `Packages/RenderCore/Tests/RenderCoreTests/AspectPresetTests.swift` (create)

**Interfaces:**
- Produces: `public enum AspectPreset: String, Codable, CaseIterable, Sendable { case auto, wide16x9, classic4x3, square, vertical9x16 }` with `public var ratio: CGFloat?` and `public func canvasSize(for source: CGSize) -> CGSize`; new field `public var aspect: AspectPreset?` on `RenderSettings`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RenderCore

final class AspectPresetTests: XCTestCase {
    let source = CGSize(width: 3000, height: 2000) // 3:2

    func testAutoReturnsSource() {
        XCTAssertEqual(AspectPreset.auto.canvasSize(for: source), source)
    }

    func testWiderPresetExtendsWidth() {
        // 16:9 is wider than 3:2 → keep height, widen. 2000 * 16/9 = 3555.55 → 3554 (even).
        let s = AspectPreset.wide16x9.canvasSize(for: source)
        XCTAssertEqual(s.height, 2000)
        XCTAssertEqual(s.width, 3554)
        XCTAssertEqual(Int(s.width) % 2, 0)
    }

    func testNarrowerPresetExtendsHeight() {
        // 1:1 is narrower than 3:2 → keep width, heighten. 3000x3000.
        XCTAssertEqual(AspectPreset.square.canvasSize(for: source), CGSize(width: 3000, height: 3000))
    }

    func testVerticalPreset() {
        // 9:16 → keep width, height = 3000 * 16/9 = 5333.33 → 5332 (even).
        let s = AspectPreset.vertical9x16.canvasSize(for: source)
        XCTAssertEqual(s, CGSize(width: 3000, height: 5332))
    }

    func testRenderSettingsDecodesWithoutAspect() throws {
        // Additive: settings persisted before the field existed decode to nil.
        let data = try JSONEncoder().encode(RenderSettings.default)
        let decoded = try JSONDecoder().decode(RenderSettings.self, from: data)
        XCTAssertNil(decoded.aspect)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --package-path Packages/RenderCore --filter AspectPresetTests` → FAIL (`AspectPreset` undefined).

- [ ] **Step 3: Implement** in `RenderSettings.swift`:

```swift
/// Output canvas aspect. `auto` matches the recording; presets extend the canvas on one axis
/// (never cropping content — `CanvasLayout` already fits the screen inside whatever canvas it gets).
public enum AspectPreset: String, Codable, CaseIterable, Sendable {
    case auto, wide16x9, classic4x3, square, vertical9x16

    public var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .wide16x9: 16.0 / 9.0
        case .classic4x3: 4.0 / 3.0
        case .square: 1
        case .vertical9x16: 9.0 / 16.0
        }
    }

    /// Canvas for a given source (screen) size: keeps the axis that already fills the preset and
    /// extends the other, rounded down to even pixels (codec requirement).
    public func canvasSize(for source: CGSize) -> CGSize {
        guard let ratio else { return source }
        func even(_ v: CGFloat) -> CGFloat { let f = floor(v); return f - f.truncatingRemainder(dividingBy: 2) }
        let sourceAspect = source.width / source.height
        if ratio >= sourceAspect {
            return CGSize(width: even(source.height * ratio), height: even(source.height))
        }
        return CGSize(width: even(source.width), height: even(source.width / ratio))
    }
}
```

Add to `RenderSettings`: `public var aspect: AspectPreset?` (declared after `cursorSize`), add `aspect: AspectPreset? = nil` to the memberwise `init` and assign it. (Codable synthesis keeps it optional → additive.)

- [ ] **Step 4: Run to verify pass** — same command → PASS. Also run the full package (`swift test --package-path Packages/RenderCore`) to catch `init` call sites.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(rendercore): AspectPreset canvas sizing"`

---

### Task 2: Spring zoom envelope + low-pass pan (RenderCore)

**Files:**
- Modify: `Packages/RenderCore/Sources/RenderCore/AutoZoom.swift` (the `ZoomTimeline` enum + `AutoZoom.postClickHold`)
- Test: `Packages/RenderCore/Tests/RenderCoreTests/AutoZoomTests.swift` (extend; update any assertions that encode the old smoothstep/glide numbers)

**Interfaces:**
- Consumes: existing `ZoomSegment`, `FocusKey`, `ZoomState`.
- Produces: same public API (`ZoomTimeline.state(at:segments:)` unchanged); new internals `ZoomTimeline.springStep(_:settle:)`, `ZoomTimeline.decay(_:toward:over:)`, `ZoomTimeline.panTau`.

- [ ] **Step 1: Write the failing tests** (append to `AutoZoomTests.swift`):

```swift
func testSpringStepEndpointsAndMonotonicity() {
    XCTAssertEqual(ZoomTimeline.springStep(0, settle: 0.8), 0)
    XCTAssertEqual(ZoomTimeline.springStep(-1, settle: 0.8), 0)
    XCTAssertGreaterThan(ZoomTimeline.springStep(0.8, settle: 0.8), 0.985) // settled at d
    var prev = -1.0
    for i in 0...100 {
        let v = ZoomTimeline.springStep(Double(i) * 0.02, settle: 0.8)
        XCTAssertGreaterThanOrEqual(v, prev)   // monotone
        XCTAssertLessThanOrEqual(v, 1.0)       // never overshoots
        prev = v
    }
}

func testSpringStepStartsGently() {
    // Zero velocity at t=0: the first 5% of the settle time moves < 2% of the range.
    XCTAssertLessThan(ZoomTimeline.springStep(0.04, settle: 0.8), 0.02)
}

func testEnvelopeUsesSpringAndStaysContinuous() {
    let s = ZoomSegment(start: 1, end: 6, easeIn: 0.8, easeOut: 0.8,
                        focus: CGPoint(x: 0.5, y: 0.5), scale: 2)
    XCTAssertEqual(ZoomTimeline.envelope(0.9, s), 0)          // before
    XCTAssertGreaterThan(ZoomTimeline.envelope(3.5, s), 0.99) // held ≈ 1
    // Continuity: no jump larger than what 60fps stepping explains.
    var prev = 0.0
    for i in 0...300 {
        let v = ZoomTimeline.envelope(1 + Double(i) / 60.0, s)
        XCTAssertLessThan(abs(v - prev), 0.08)
        prev = v
    }
}

func testPanFilterConvergesWithoutOvershoot() {
    let keys = [FocusKey(time: 1, point: CGPoint(x: 0.3, y: 0.3)),
                FocusKey(time: 2, point: CGPoint(x: 0.7, y: 0.6))]
    XCTAssertEqual(ZoomTimeline.focus(at: 0.5, keys: keys), CGPoint(x: 0.3, y: 0.3)) // frozen pre-first-key
    let mid = ZoomTimeline.focus(at: 2.2, keys: keys)
    XCTAssertGreaterThan(mid.x, 0.3); XCTAssertLessThan(mid.x, 0.7)                  // gliding, no jump
    let settled = ZoomTimeline.focus(at: 5.0, keys: keys)
    XCTAssertEqual(settled.x, 0.7, accuracy: 0.01)                                   // converges
    XCTAssertEqual(settled.y, 0.6, accuracy: 0.01)
    // Never overshoots the target axis-wise.
    for i in 0...100 {
        let p = ZoomTimeline.focus(at: 1 + Double(i) * 0.05, keys: keys)
        XCTAssertLessThanOrEqual(p.x, 0.7 + 1e-9)
        XCTAssertLessThanOrEqual(p.y, 0.6 + 1e-9)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --package-path Packages/RenderCore --filter AutoZoomTests` → FAIL (`springStep` undefined).

- [ ] **Step 3: Implement** — replace `ZoomTimeline`'s `envelope`, `focus`, `smoothstep`, and `panDuration`:

```swift
public enum ZoomTimeline {
    /// One-pole low-pass time constant for cursor-follow pans (Screen Charm feel: heavy smoothing).
    static let panTau = 0.35

    public static func state(at t: Double, segments: [ZoomSegment]) -> ZoomState {
        guard let s = segments.first(where: { t >= $0.start && t < $0.end }) else { return .identity }
        let f = envelope(t, s)
        return ZoomState(scale: 1 + (s.scale - 1) * f, focus: focus(at: t, keys: s.focusKeys),
                         progress: f)
    }

    /// Critically damped spring step response: quadratic start (zero velocity at 0), exponential
    /// settle, mathematically incapable of overshoot. Reaches ~0.99 of the range at `settle`.
    static func springStep(_ t: Double, settle d: Double) -> Double {
        guard t > 0 else { return 0 }
        guard d > 1e-6 else { return 1 }
        let x = 6.64 / d * t // ω·d = 6.64 ⇒ p(d) ≈ 0.99
        return 1 - (1 + x) * exp(-x)
    }

    /// Spring in from the start, spring out toward the end; `min` composes the two so short
    /// segments stay continuous (they simply never reach a full hold).
    static func envelope(_ t: Double, _ s: ZoomSegment) -> Double {
        guard t >= s.start, t < s.end else { return 0 }
        return min(springStep(t - s.start, settle: max(s.easeIn, 0.15)),
                   springStep(s.end - t, settle: max(s.easeOut, 0.15)))
    }

    /// Focus at `t`: the key points are step targets; the camera runs them through a one-pole
    /// low-pass filter (closed form, piecewise-exponential — deterministic for export). Before the
    /// first key the focus is pinned to it (the zoom-in grows toward it, no pan while easing).
    static func focus(at t: Double, keys: [FocusKey]) -> CGPoint {
        guard var target = keys.first?.point else { return CGPoint(x: 0.5, y: 0.5) }
        guard keys.count > 1, t > keys[0].time else { return target }
        var pos = target
        var clock = keys[0].time
        for key in keys.dropFirst() where key.time < t {
            pos = decay(pos, toward: target, over: key.time - clock)
            target = key.point
            clock = key.time
        }
        return decay(pos, toward: target, over: t - clock)
    }

    static func decay(_ p: CGPoint, toward target: CGPoint, over dt: Double) -> CGPoint {
        guard dt > 0 else { return p }
        let a = 1 - exp(-dt / panTau)
        return CGPoint(x: p.x + (target.x - p.x) * a, y: p.y + (target.y - p.y) * a)
    }
}
```

In `AutoZoom`, retune `postClickHold` from `1.0` to `1.3` (Screen Charm's idle-before-zoom-out).

- [ ] **Step 4: Run the whole package** — `swift test --package-path Packages/RenderCore`. Fix any existing assertions that encoded smoothstep values or `panDuration` glide timing (keep the *behaviors*: envelope 0 outside segments, focus clamped keys, non-overlap). Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat(rendercore): damped-spring zoom envelope + low-pass pan follow"`

---

### Task 3: Playback speed (retiming for export, rate for preview) (RenderCore)

**Files:**
- Modify: `Packages/RenderCore/Sources/RenderCore/RenderSettings.swift` (add field)
- Modify: `Packages/RenderCore/Sources/RenderCore/AutoZoom.swift` (add `ZoomSegment.scaled(by:)`)
- Modify: `Packages/RenderCore/Sources/RenderCore/AV/ProjectCompositionBuilder.swift`
- Modify: `Packages/RenderCore/Sources/RenderCore/AV/ProjectExporter.swift`
- Test: `Packages/RenderCore/Tests/RenderCoreTests/PlaybackSpeedTests.swift` (create)

**Interfaces:**
- Produces: `RenderSettings.playbackSpeed: Double?` (nil = 1); `ZoomSegment.scaled(by factor: Double) -> ZoomSegment`; `ProjectCompositionBuilder.build(..., retimeForExport: Bool = false)`.
- Consumers: preview keeps `retimeForExport: false` (player rate handles speed); `ProjectExporter` passes `true` and divides trim times by speed.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RenderCore

final class PlaybackSpeedTests: XCTestCase {
    func testZoomSegmentScaling() {
        let s = ZoomSegment(start: 2, end: 6, easeIn: 0.8, easeOut: 0.5,
                            focusKeys: [FocusKey(time: 2.5, point: .init(x: 0.4, y: 0.4))],
                            scale: 2) // adjust arg order to the real initializer
        let half = s.scaled(by: 0.5) // 2x speed → times halve
        XCTAssertEqual(half.start, 1); XCTAssertEqual(half.end, 3)
        XCTAssertEqual(half.easeIn, 0.4); XCTAssertEqual(half.easeOut, 0.25)
        XCTAssertEqual(half.focusKeys[0].time, 1.25)
        XCTAssertEqual(half.scale, 2) // magnification untouched
    }

    func testSettingsDecodeWithoutSpeed() throws {
        let decoded = try JSONDecoder().decode(
            RenderSettings.self, from: JSONEncoder().encode(RenderSettings.default))
        XCTAssertNil(decoded.playbackSpeed)
    }
}
```

(Use the real `ZoomSegment` initializer: `ZoomSegment(start:end:easeIn:easeOut:scale:focusKeys:)`.)

- [ ] **Step 2: Run to verify failure** — `--filter PlaybackSpeedTests` → FAIL.

- [ ] **Step 3: Implement.**

`RenderSettings`: add `public var playbackSpeed: Double?` (+ init param, additive).

`ZoomSegment` extension in `AutoZoom.swift`:

```swift
public extension ZoomSegment {
    /// Maps every time-domain value into a retimed composition (factor = 1/speed).
    func scaled(by factor: Double) -> ZoomSegment {
        ZoomSegment(start: start * factor, end: end * factor,
                    easeIn: easeIn * factor, easeOut: easeOut * factor,
                    scale: scale,
                    focusKeys: focusKeys.map { FocusKey(time: $0.time * factor, point: $0.point) })
    }
}
```

`ProjectCompositionBuilder.build` — add `retimeForExport: Bool = false` parameter. After all tracks are inserted, before creating the instruction:

```swift
let speed = settings.playbackSpeed ?? 1
var zoomSegments = settings.zooms.map { $0.map(\.segment) }
    ?? AutoZoom.segments(clicks: clicks, settings: settings.autoZoom ?? .default)
var samples = cursorSamples
if retimeForExport, abs(speed - 1) > 0.001 {
    let full = CMTimeRange(start: .zero, duration: composition.duration)
    composition.scaleTimeRange(
        full, toDuration: CMTime(seconds: full.duration.seconds / speed, preferredTimescale: 600))
    zoomSegments = zoomSegments.map { $0.scaled(by: 1 / speed) }
    samples = samples.map { CursorSample(time: $0.time / speed, point: $0.point) }
}
```

Use `zoomSegments`/`samples` in the `CharmInstruction`, and keep the instruction's `timeRange` computed from the (now possibly scaled) `composition.duration`.

`ProjectExporter.export`: pass `retimeForExport: true` to `build`, and where trim is applied (`settings.trimStart/... trimEnd`) divide both by `settings.playbackSpeed ?? 1`. Where the audio reader output is created (`AVAssetReaderAudioMixOutput`), set `audioTimePitchAlgorithm = .timeDomain` so retimed audio keeps its pitch.

- [ ] **Step 4: Run full package tests** — `swift test --package-path Packages/RenderCore` → PASS (fix `build(...)` test call sites if any assert on the old signature).
- [ ] **Step 5: Commit** — `git commit -am "feat(rendercore): playback speed — export retiming + pitch-preserved audio"`

---

### Task 4: Background blur + webcam content zoom (RenderCore)

**Files:**
- Modify: `Packages/RenderCore/Sources/RenderCore/RenderSettings.swift` (two fields)
- Modify: `Packages/RenderCore/Sources/RenderCore/Compositor.swift`
- Test: `Packages/RenderCore/Tests/RenderCoreTests/CompositorCanvasTests.swift` (extend, following its existing render-and-inspect style)

**Interfaces:**
- Produces: `RenderSettings.backgroundBlur: Double?` (0–1); `WebcamSettings.contentZoom: Double?` (1–2, crop-zoom inside the bubble).

- [ ] **Step 1: Write the failing test** (match the existing test file's helpers for rendering a `Compositor` output to pixels; the shape below is the intent):

```swift
func testBackgroundBlurSoftensGradient() throws {
    var settings = RenderSettings.default
    settings.backgroundBlur = 1.0
    // Render a small canvas twice (blur off/on) and compare a pixel near the gradient's
    // sharpest edge: blurred must differ from unblurred, and both render without crashing.
    // (Reuse this file's existing CIContext + render helpers.)
}

func testContentZoomFieldIsAdditive() throws {
    let decoded = try JSONDecoder().decode(
        RenderSettings.self, from: JSONEncoder().encode(RenderSettings.default))
    XCTAssertNil(decoded.webcam.contentZoom)
    XCTAssertNil(decoded.backgroundBlur)
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**

`RenderSettings.swift`: add `public var backgroundBlur: Double?` to `RenderSettings` and `public var contentZoom: Double?` to `WebcamSettings` (+ init params, additive).

`Compositor.render`: after `backgroundLayer(...)`:

```swift
if let blur = settings.backgroundBlur, blur > 0.001 {
    let sigma = blur * 0.04 * min(canvasSize.width, canvasSize.height)
    result = result.clampedToExtent()
        .applyingGaussianBlur(sigma: sigma)
        .cropped(to: canvasRect)
}
```

`webcamLayer`: where the webcam source is center-cropped to a square for the bubble, divide the crop side by `max(1, settings.webcam.contentZoom ?? 1)` (still centered) so the bubble shows a tighter crop of the face.

- [ ] **Step 4: Run full package tests** → PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat(rendercore): background blur + webcam content zoom"`

---

### Task 5: StylingModel — undo/redo, speed preview, aspect canvas, zoom default, wallpapers

**Files:**
- Modify: `App/Styling/StylingModel.swift`
- Create: `App/Studio/SystemWallpapers.swift`

**Interfaces (later tasks rely on these exact names):**
- `model.canvasSize: CGSize` — aspect-adjusted canvas (replaces raw `sourceCanvasSize` for layout math and builder calls).
- `model.undoEdit()`, `model.redoEdit()`, `@Published private(set) var canUndo: Bool`, `canRedo: Bool`.
- `SystemWallpapers.curated: [URL]`, `SystemWallpapers.all() -> [URL]`, `SystemWallpapers.thumbnail(_ url: URL, height: CGFloat) -> NSImage?`.

- [ ] **Step 1: Undo/redo.** In `StylingModel`:

```swift
private struct EditSnapshot: Equatable {
    var render: RenderSettings
    var audio: AudioSettings
}
let editUndo = UndoManager()
@Published private(set) var canUndo = false
@Published private(set) var canRedo = false
private var isRestoring = false
private var lastUndoRegistration = Date.distantPast
```

Change the property observers to pass the old value:

```swift
@Published var renderSettings: RenderSettings {
    didSet { renderSettingsChanged(old: oldValue) }
}
@Published var audioSettings: AudioSettings {
    didSet { audioSettingsChanged(old: oldValue) }
}
```

and in the changed-handlers (before the existing debounce work), record the undo point:

```swift
private func renderSettingsChanged(old: RenderSettings) {
    if isLoaded, !isRestoring, old != renderSettings {
        recordUndo(EditSnapshot(render: old, audio: audioSettings))
        hasUnsavedChanges = true
    }
    rebuildVideoComposition()
    persist()
}
```

(audio analog: snapshot uses `EditSnapshot(render: renderSettings, audio: old)`.)

```swift
/// One undo record per discrete edit. Continuous slider drags coalesce: registrations within
/// 0.8 s extend the previous record instead of stacking one per tick.
private func recordUndo(_ old: EditSnapshot) {
    let now = Date()
    defer { lastUndoRegistration = now }
    if now.timeIntervalSince(lastUndoRegistration) < 0.8 { refreshUndoFlags(); return }
    editUndo.registerUndo(withTarget: self) { model in
        MainActor.assumeIsolated { model.restore(old) }
    }
    refreshUndoFlags()
}

/// Applies a snapshot and registers the inverse (UndoManager routes it to the redo stack
/// automatically while undoing).
private func restore(_ snap: EditSnapshot) {
    let current = EditSnapshot(render: renderSettings, audio: audioSettings)
    isRestoring = true
    if renderSettings != snap.render { renderSettings = snap.render }
    if audioSettings != snap.audio {
        audioSettings = snap.audio
    }
    isRestoring = false
    hasUnsavedChanges = true
    editUndo.registerUndo(withTarget: self) { model in
        MainActor.assumeIsolated { model.restore(current) }
    }
    refreshUndoFlags()
}

func undoEdit() { lastUndoRegistration = .distantPast; editUndo.undo(); refreshUndoFlags() }
func redoEdit() { lastUndoRegistration = .distantPast; editUndo.redo(); refreshUndoFlags() }
private func refreshUndoFlags() { canUndo = editUndo.canUndo; canRedo = editUndo.canRedo }
```

Note: `restore` still runs the rebuild paths because the didSets fire (guarded from re-recording by `isRestoring`).

- [ ] **Step 2: Aspect-adjusted canvas + speed preview + zoom default.**

```swift
/// The output canvas: the recording's size, extended per the aspect preset.
var canvasSize: CGSize {
    (renderSettings.aspect ?? .auto).canvasSize(for: sourceCanvasSize)
}
```

- In `rebuildComposition()` and `rebuildVideoComposition()`, change `let canvas = sourceCanvasSize` to `let canvas = canvasSize`.
- In both, after creating/refreshing the player item set `item.audioTimePitchAlgorithm = .timeDomain`, and set `player.defaultRate = Float(renderSettings.playbackSpeed ?? 1)`.
- In `renderSettingsChanged`, also re-apply `player.defaultRate` and, if `isPlaying`, `player.rate = Float(renderSettings.playbackSpeed ?? 1)` so a speed change takes effect mid-playback.
- In `addZoom`, replace the hardcoded `scale: 2.0` with `scale: renderSettings.autoZoom?.level ?? 2.0`.
- `WebcamDragOverlay` (in `PlayerView.swift`): replace `model.sourceCanvasSize` with `model.canvasSize` so bubble hit-testing tracks the aspect-extended canvas.

- [ ] **Step 3: Wallpapers helper.** Create `App/Studio/SystemWallpapers.swift`:

```swift
import AppKit

/// macOS system wallpapers (`/System/Library/Desktop Pictures/*.heic`) — the same imagery the
/// reference editor bundles, already on every Mac. No assets shipped.
enum SystemWallpapers {
    static let directory = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
    /// Names shown in the panel's grid, in display order; missing ones are skipped.
    private static let curatedNames = [
        "Sequoia", "Sonoma", "Ventura Graphic", "Monterey Graphic",
        "Big Sur Graphic Light", "Big Sur", "Radial Sky Blue",
        "iMac Blue", "iMac Purple", "iMac Orange",
    ]

    static var curated: [URL] {
        curatedNames.compactMap { name in
            let url = directory.appendingPathComponent("\(name).heic")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    static func all() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "heic" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Small decode via CGImageSource so a grid of 6K wallpapers stays cheap.
    static func thumbnail(_ url: URL, height: CGFloat = 44) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(height * 4),
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }
}
```

- [ ] **Step 4: Build** — `make build` → succeeds. Old UI still runs (aspect/speed simply have no controls yet).
- [ ] **Step 5: Commit** — `git commit -am "feat(app): undo/redo snapshots, aspect canvas, speed preview, wallpaper source"`

---

### Task 6: StudioTheme + dark window chrome + root scaffold

**Files:**
- Create: `App/Studio/StudioTheme.swift`
- Create: `App/Studio/StudioRootView.swift`
- Modify: `App/Studio/StudioWindowController.swift`

**Interfaces:**
- Produces: `enum StudioTheme` tokens (`windowBG`, `panelBG`, `chipBG`, `chipBorder`, `accent`, `textPrimary`, `textSecondary`), `ChipButtonStyle`, `SegmentChips`, `PanelSection`, `StudioSlider`.
- `StudioRootView(model: StylingModel)` — the window's new root; this task scaffolds it hosting the toolbar/rail placeholders plus the EXISTING `PlayerView`/`WebcamDragOverlay` and old `StudioTimeline` so the app is fully usable at this commit.

- [ ] **Step 1: Theme.** Create `App/Studio/StudioTheme.swift`:

```swift
import SwiftUI

/// Design tokens for the Studio chrome — one source of truth, no ad-hoc colors in views.
enum StudioTheme {
    static let windowBG = Color(.sRGB, red: 0.051, green: 0.051, blue: 0.063)   // #0D0D10
    static let panelBG = Color(.sRGB, red: 0.102, green: 0.102, blue: 0.118)    // #1A1A1E
    static let chipBG = Color(.sRGB, red: 0.137, green: 0.137, blue: 0.157)     // #232328
    static let chipBorder = Color.white.opacity(0.08)
    static let accent = Color(.sRGB, red: 0.42, green: 0.36, blue: 0.91)        // indigo (Export)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let cornerRadius: CGFloat = 10
}

/// The dark rounded "chip" every toolbar/transport button uses.
struct ChipButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                    .fill(prominent ? StudioTheme.accent : StudioTheme.chipBG))
            .overlay(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                .stroke(StudioTheme.chipBorder, lineWidth: prominent ? 0 : 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Horizontal chip row bound to one value — the reference's segmented control idiom.
struct SegmentChips<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == option.value
                            ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(selection == option.value
                                ? StudioTheme.chipBG : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(selection == option.value
                                ? StudioTheme.accent : StudioTheme.chipBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Titled block inside an inspector panel ("Aspect Ratio", "Background", …).
struct PanelSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
            if let subtitle {
                Text(subtitle).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

/// Labeled slider row in the panel style.
struct StudioSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
            Slider(value: $value, in: range).tint(StudioTheme.accent)
        }
    }
}
```

- [ ] **Step 2: Root scaffold.** Create `App/Studio/StudioRootView.swift` — temporarily reuses the old timeline so every commit ships a working editor:

```swift
import SwiftUI

struct StudioRootView: View {
    @StateObject var model: StylingModel

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbarPlaceholder(model: model) // replaced by StudioToolbar in the next task
            HStack(spacing: 0) {
                // Rail + panels land in Task 7/8; old inspector keeps the app usable meanwhile.
                InspectorView(model: model)
                ZStack {
                    PlayerView(player: model.player)
                    WebcamDragOverlay(model: model)
                    if model.processingAudio {
                        ProgressView("Processing audio…")
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(minWidth: 480, minHeight: 320)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            StudioTimeline(model: model)
        }
        .background(StudioTheme.windowBG)
        .preferredColorScheme(.dark)
        .alert("OpenCharm", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.showExport) {
            ExportSheet(model: ExportModel(styling: model))
        }
        .overlay {
            if model.isSaving {
                ProgressView("Saving…").padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// Interim strip: Save/Export until StudioToolbar replaces it.
private struct StudioToolbarPlaceholder: View {
    @ObservedObject var model: StylingModel
    var body: some View {
        HStack {
            Spacer()
            Button("Save") { Task { await model.saveProject() } }.keyboardShortcut("s")
            Button("Export…") { model.showExport = true }.keyboardShortcut("e")
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }
}
```

- [ ] **Step 3: Window chrome.** In `StudioWindowController.init`, after creating the window:

```swift
window.styleMask.insert(.fullSizeContentView)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.appearance = NSAppearance(named: .darkAqua)
window.backgroundColor = NSColor(red: 0.051, green: 0.051, blue: 0.063, alpha: 1)
window.minSize = NSSize(width: 1100, height: 640)
```

and in `show(package:savedArchive:)` swap the root: `window?.contentView = NSHostingView(rootView: StudioRootView(model: model))`.

`StudioRootView` takes `@StateObject` but the controller passes a cached model; change to `@ObservedObject var model: StylingModel` (the controller owns model lifetime, matching current design).

- [ ] **Step 4: Build + run** — `make build`; launch, open a project, confirm the dark window with transparent titlebar renders and edits still work.
- [ ] **Step 5: Commit** — `git commit -am "feat(studio): dark chrome window + theme + root scaffold"`

---

### Task 7: StudioToolbar

**Files:**
- Create: `App/Studio/StudioToolbar.swift`
- Modify: `App/Studio/StudioRootView.swift` (replace the placeholder)

**Interfaces:**
- Consumes: `model.projectName`, `model.hasUnsavedChanges`, `model.canUndo/canRedo/undoEdit()/redoEdit()`, `model.showExport`, `AppModel.shared?.openProjectPanel()`, `AppModel.shared?.showDock()`.

- [ ] **Step 1: Implement** `App/Studio/StudioToolbar.swift`:

```swift
import SwiftUI

/// Screen-Charm-style title strip: icon cluster left of center, project name centered,
/// primary actions on the right. Sits under the transparent titlebar; leading padding
/// clears the traffic lights.
struct StudioToolbar: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                Text(model.projectName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(".charmproj")
                    .font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
                if model.hasUnsavedChanges {
                    Circle().fill(StudioTheme.textSecondary).frame(width: 6, height: 6)
                        .padding(.leading, 2)
                        .help("Edited since last save")
                }
            }
            HStack(spacing: 10) {
                Spacer().frame(width: 78) // traffic lights
                iconButton("folder", help: "Open project…") {
                    AppModel.shared?.openProjectPanel()
                }
                iconButton("arrow.uturn.backward", help: "Undo") { model.undoEdit() }
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                iconButton("arrow.uturn.forward", help: "Redo") { model.redoEdit() }
                    .disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Spacer()
                Button {
                    AppModel.shared?.showDock()
                } label: { Label("New recording", systemImage: "record.circle") }
                    .buttonStyle(ChipButtonStyle())
                Button {
                    model.showExport = true
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .keyboardShortcut("e")
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 52)
        .background(StudioTheme.windowBG)
    }

    private func iconButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
```

- [ ] **Step 2:** In `StudioRootView`, replace `StudioToolbarPlaceholder(model: model)` with `StudioToolbar(model: model)` and delete the placeholder struct. Keep ⌘S working by adding to the root view: `.background { Button("") { Task { await model.saveProject() } }.keyboardShortcut("s").hidden() }`.
- [ ] **Step 3: Build + run** — verify title, undo/redo enable/disable as you tweak a slider, New recording shows the dock, Export opens the sheet.
- [ ] **Step 4: Commit** — `git commit -am "feat(studio): custom toolbar with undo/redo + new recording"`

---

### Task 8: Sidebar rail + inspector panels

**Files:**
- Create: `App/Studio/SidebarRail.swift`
- Create: `App/Studio/Panels/GeneralPanel.swift`
- Create: `App/Studio/Panels/CursorPanel.swift`
- Create: `App/Studio/Panels/SoundPanel.swift`
- Create: `App/Studio/Panels/CameraPanel.swift`
- Modify: `App/Studio/StudioRootView.swift` (swap `InspectorView` for rail + panel)

**Interfaces:**
- Produces: `enum StudioSection: String, CaseIterable { case general, cursor, sound, camera }`; `SidebarRail(selection: Binding<StudioSection>)`; the four panel views, each `(model: StylingModel)`.
- Consumes: theme components from Task 6, `SystemWallpapers` from Task 5, binding helpers ported from the old `InspectorView` (`backgroundKind`, `solidColor`, `cornerPreset`, `autoZoom*`, `cursorSize`, `chooseImage()`).

- [ ] **Step 1: Rail.** `App/Studio/SidebarRail.swift`:

```swift
import SwiftUI

enum StudioSection: String, CaseIterable, Identifiable {
    case general, cursor, sound, camera
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: "General"; case .cursor: "Cursor"
        case .sound: "Sound"; case .camera: "Camera"
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"; case .cursor: "cursorarrow"
        case .sound: "speaker.wave.2"; case .camera: "video"
        }
    }
}

struct SidebarRail: View {
    @Binding var selection: StudioSection

    var body: some View {
        VStack(spacing: 6) {
            ForEach(StudioSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.symbol).font(.system(size: 16, weight: .medium))
                        Text(section.label).font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(selection == section
                        ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .frame(width: 56, height: 50)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(selection == section ? StudioTheme.chipBG : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 72)
        .background(StudioTheme.windowBG)
    }
}
```

- [ ] **Step 2: General panel.** `App/Studio/Panels/GeneralPanel.swift` — the big one; port the binding helpers from the old `InspectorView` verbatim where noted:

```swift
import AppKit
import RenderCore
import SwiftUI

struct GeneralPanel: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PanelSection(title: "Camera Layout", subtitle: "Webcam over screen") {
                    cameraLayoutRow
                }
                PanelSection(title: "Aspect Ratio", subtitle: "Auto matches your recording") {
                    SegmentChips(options: [
                        ("Auto", AspectPreset.auto), ("16:9", .wide16x9), ("4:3", .classic4x3),
                        ("1:1", .square), ("9:16", .vertical9x16),
                    ], selection: aspect)
                }
                PanelSection(title: "Background") { backgroundPicker }
                PanelSection(title: "Playback Speed") {
                    SegmentChips(options: [("0.5×", 0.5), ("0.75×", 0.75), ("1×", 1.0),
                                           ("1.25×", 1.25), ("1.5×", 1.5), ("2×", 2.0)],
                                 selection: playbackSpeed)
                }
                PanelSection(title: "Zoom Level", subtitle: "Default for new and auto zooms") {
                    SegmentChips(options: [("1.5×", 1.5), ("1.75×", 1.75), ("2×", 2.0),
                                           ("2.25×", 2.25), ("2.5×", 2.5)],
                                 selection: zoomLevel)
                    Toggle("Zoom in on clicks", isOn: autoZoomEnabled)
                        .toggleStyle(.switch).tint(StudioTheme.accent)
                        .font(.system(size: 12))
                }
                PanelSection(title: "Canvas") {
                    StudioSlider(label: "Padding",
                                 value: $model.renderSettings.paddingFraction, range: 0...0.25)
                    StudioSlider(label: "Corner radius",
                                 value: $model.renderSettings.cornerRadiusFraction, range: 0...0.2)
                    StudioSlider(label: "Shadow",
                                 value: $model.renderSettings.shadow.opacity, range: 0...1)
                    StudioSlider(label: "Background blur", value: backgroundBlur, range: 0...1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .frame(width: 280)
        .background(StudioTheme.panelBG)
    }

    // Camera layout presets: five thumbnails writing WebcamSettings placement.
    private var cameraLayoutRow: some View {
        HStack(spacing: 8) {
            layoutThumb(center: CGPoint(x: 0.13, y: 0.82), size: 0.48, visible: true) // big bubble BL
            layoutThumb(center: CGPoint(x: 0.87, y: 0.82), size: 0.3, visible: true)  // small BR
            layoutThumb(center: CGPoint(x: 0.13, y: 0.18), size: 0.3, visible: true)  // small TL
            layoutThumb(center: CGPoint(x: 0.87, y: 0.18), size: 0.3, visible: true)  // small TR
            layoutThumb(center: .zero, size: 0, visible: false)                        // hidden
        }
    }

    private func layoutThumb(center: CGPoint, size: Double, visible: Bool) -> some View {
        let isCurrent = model.renderSettings.webcam.visible == visible
            && (!visible || (model.renderSettings.webcam.center == center
                             && abs(model.renderSettings.webcam.size - size) < 0.01))
        return Button {
            model.renderSettings.webcam.visible = visible
            if visible {
                model.renderSettings.webcam.center = center
                model.renderSettings.webcam.size = size
            }
        } label: {
            ZStack(alignment: alignment(for: center)) {
                RoundedRectangle(cornerRadius: 6).fill(StudioTheme.chipBG)
                if visible {
                    Circle().fill(StudioTheme.textSecondary)
                        .frame(width: size > 0.4 ? 16 : 10, height: size > 0.4 ? 16 : 10)
                        .padding(4)
                }
            }
            .frame(width: 44, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? StudioTheme.accent : StudioTheme.chipBorder,
                        lineWidth: isCurrent ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func alignment(for center: CGPoint) -> Alignment {
        switch (center.x < 0.5, center.y < 0.5) {
        case (true, true): .topLeading
        case (false, true): .topTrailing
        case (true, false): .bottomLeading
        case (false, false): .bottomTrailing
        }
    }

    // Background: Image / Gradient / Color tabs.
    @State private var bgTab = "image"
    private var backgroundPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SegmentChips(options: [("Image", "image"), ("Gradient", "gradient"),
                                   ("Color", "solid")], selection: $bgTab)
            switch bgTab {
            case "image":
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(SystemWallpapers.curated, id: \.self) { url in
                        wallpaperThumb(url)
                    }
                }
                HStack {
                    Button("Pick random") {
                        if let url = SystemWallpapers.all().randomElement() {
                            model.renderSettings.background = .image(path: url.path)
                        }
                    }.buttonStyle(ChipButtonStyle())
                    Button("Upload custom…") { chooseImage() }.buttonStyle(ChipButtonStyle())
                }
            case "gradient":
                let presets: [(RGBAColor, RGBAColor)] = [
                    (RGBAColor(r: 0.28, g: 0.18, b: 0.55), RGBAColor(r: 0.10, g: 0.35, b: 0.60)),
                    (RGBAColor(r: 0.95, g: 0.45, b: 0.20), RGBAColor(r: 0.85, g: 0.15, b: 0.45)),
                    (RGBAColor(r: 0.05, g: 0.45, b: 0.35), RGBAColor(r: 0.10, g: 0.20, b: 0.35)),
                    (RGBAColor(r: 0.55, g: 0.20, b: 0.65), RGBAColor(r: 0.15, g: 0.15, b: 0.50)),
                    (RGBAColor(r: 0.10, g: 0.10, b: 0.14), RGBAColor(r: 0.30, g: 0.30, b: 0.38)),
                ]
                HStack(spacing: 8) {
                    ForEach(0..<presets.count, id: \.self) { i in
                        let (a, b) = presets[i]
                        Button {
                            model.renderSettings.background =
                                .linearGradient(start: a, end: b, angleDegrees: 35)
                        } label: {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LinearGradient(
                                    colors: [Color(red: a.r, green: a.g, blue: a.b),
                                             Color(red: b.r, green: b.g, blue: b.b)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 40, height: 30)
                        }.buttonStyle(.plain)
                    }
                }
            default:
                ColorPicker("Color", selection: solidColor, supportsOpacity: false)
                    .font(.system(size: 12))
            }
        }
        .onAppear { bgTab = currentBackgroundKind }
    }

    private func wallpaperThumb(_ url: URL) -> some View {
        let selected = model.renderSettings.background == .image(path: url.path)
        return Button {
            model.renderSettings.background = .image(path: url.path)
        } label: {
            Group {
                if let img = SystemWallpapers.thumbnail(url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else { StudioTheme.chipBG }
            }
            .frame(width: 44, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? StudioTheme.accent : StudioTheme.chipBorder,
                        lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var currentBackgroundKind: String {
        switch model.renderSettings.background {
        case .solid: "solid"; case .linearGradient: "gradient"; case .image: "image"
        }
    }

    // Bindings (ported from the old InspectorView, same semantics).
    private var aspect: Binding<AspectPreset> {
        Binding { model.renderSettings.aspect ?? .auto }
        set: { model.renderSettings.aspect = $0 == .auto ? nil : $0 }
    }
    private var playbackSpeed: Binding<Double> {
        Binding { model.renderSettings.playbackSpeed ?? 1 }
        set: { model.renderSettings.playbackSpeed = $0 == 1 ? nil : $0 }
    }
    private var backgroundBlur: Binding<Double> {
        Binding { model.renderSettings.backgroundBlur ?? 0 }
        set: { model.renderSettings.backgroundBlur = $0 < 0.005 ? nil : $0 }
    }
    private var zoomLevel: Binding<Double> {
        Binding { model.renderSettings.autoZoom?.level ?? 2.0 }
        set: { var z = model.renderSettings.autoZoom ?? .default; z.level = $0
               model.renderSettings.autoZoom = z; model.regenerateAutoZooms() }
    }
    private var autoZoomEnabled: Binding<Bool> {
        Binding { model.renderSettings.autoZoom?.enabled ?? AutoZoomSettings.default.enabled }
        set: { var z = model.renderSettings.autoZoom ?? .default; z.enabled = $0
               model.renderSettings.autoZoom = z; model.regenerateAutoZooms() }
    }
    private var solidColor: Binding<Color> {
        Binding {
            if case .solid(let c) = model.renderSettings.background {
                return Color(red: c.r, green: c.g, blue: c.b)
            }
            return .black
        } set: { color in
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
            model.renderSettings.background = .solid(
                RGBAColor(r: c.redComponent, g: c.greenComponent, b: c.blueComponent))
        }
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            model.renderSettings.background = .image(path: url.path)
        }
    }
}
```

- [ ] **Step 3: The three small panels.**

`CursorPanel.swift`:

```swift
import SwiftUI

struct CursorPanel: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if model.hasSyntheticCursor {
                    PanelSection(title: "Pointer",
                                 subtitle: "Drawn in post — grows with zoom, easy to follow") {
                        StudioSlider(label: "Size", value: cursorSize, range: 0.02...0.09)
                    }
                } else {
                    PanelSection(title: "Pointer",
                                 subtitle: "This recording keeps the system cursor; "
                                     + "new recordings use the synthetic pointer.") { EmptyView() }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .frame(width: 280)
        .background(StudioTheme.panelBG)
    }

    private var cursorSize: Binding<Double> {
        Binding { model.renderSettings.cursorSize ?? 0.04 }
        set: { model.renderSettings.cursorSize = $0 }
    }
}
```

`SoundPanel.swift`:

```swift
import SwiftUI

struct SoundPanel: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PanelSection(title: "Voice") {
                    Toggle("Remove noise", isOn: $model.audioSettings.noiseRemoval)
                    Toggle("Enhance voice", isOn: $model.audioSettings.voiceEnhance)
                }
                PanelSection(title: "Levels") {
                    StudioSlider(label: "Mic volume",
                                 value: $model.audioSettings.micVolume, range: 0...2)
                    StudioSlider(label: "System volume",
                                 value: $model.audioSettings.systemVolume, range: 0...2)
                }
            }
            .toggleStyle(.switch).tint(StudioTheme.accent).font(.system(size: 12))
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .frame(width: 280)
        .background(StudioTheme.panelBG)
    }
}
```

`CameraPanel.swift`:

```swift
import RenderCore
import SwiftUI

struct CameraPanel: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PanelSection(title: "Webcam") {
                    Toggle("Show webcam", isOn: $model.renderSettings.webcam.visible)
                        .toggleStyle(.switch).tint(StudioTheme.accent).font(.system(size: 12))
                    StudioSlider(label: "Size",
                                 value: $model.renderSettings.webcam.size, range: 0.1...0.6)
                    StudioSlider(label: "Roundness",
                                 value: $model.renderSettings.webcam.roundness, range: 0...1)
                    StudioSlider(label: "Content zoom", value: contentZoom, range: 1...2)
                }
                PanelSection(title: "Position", subtitle: "Tip: drag the bubble in the preview") {
                    SegmentChips(options: [("↙", "bl"), ("↘", "br"), ("↖", "tl"), ("↗", "tr")],
                                 selection: cornerPreset)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .frame(width: 280)
        .background(StudioTheme.panelBG)
    }

    private var contentZoom: Binding<Double> {
        Binding { model.renderSettings.webcam.contentZoom ?? 1 }
        set: { model.renderSettings.webcam.contentZoom = $0 < 1.005 ? nil : $0 }
    }
    private var cornerPreset: Binding<String> {
        Binding {
            let c = model.renderSettings.webcam.center
            switch (c.x, c.y) {
            case (0.87, 0.82): return "br"; case (0.13, 0.82): return "bl"
            case (0.87, 0.18): return "tr"; case (0.13, 0.18): return "tl"
            default: return "custom"
            }
        } set: { preset in
            let centers = ["br": CGPoint(x: 0.87, y: 0.82), "bl": CGPoint(x: 0.13, y: 0.82),
                           "tr": CGPoint(x: 0.87, y: 0.18), "tl": CGPoint(x: 0.13, y: 0.18)]
            if let c = centers[preset] { model.renderSettings.webcam.center = c }
        }
    }
}
```

- [ ] **Step 4: Wire into root.** In `StudioRootView`, add `@State private var section: StudioSection = .general` and replace `InspectorView(model: model)` with:

```swift
SidebarRail(selection: $section)
Group {
    switch section {
    case .general: GeneralPanel(model: model)
    case .cursor: CursorPanel(model: model)
    case .sound: SoundPanel(model: model)
    case .camera: CameraPanel(model: model)
    }
}
```

- [ ] **Step 5: Build + run** — every control changes the preview; aspect chips reshape the canvas; wallpapers apply; undo steps back through panel edits.
- [ ] **Step 6: Commit** — `git commit -am "feat(studio): icon rail + general/cursor/sound/camera panels"`

---

### Task 9: StudioCanvas + restyled transport/timeline; delete old views

**Files:**
- Create: `App/Studio/StudioCanvas.swift`
- Create: `App/Studio/StudioTransport.swift` (port of `App/Styling/StudioTimeline.swift` — copy the file, then restyle)
- Modify: `App/Studio/StudioRootView.swift`
- Delete: `App/Styling/StylingView.swift`, `App/Styling/InspectorView.swift`, `App/Styling/StudioTimeline.swift`
- Keep: `App/Styling/PlayerView.swift` (PlayerView + WebcamDragOverlay), `StylingModel.swift`, `ClickTrack.swift`, `CursorImage.swift`

**Interfaces:**
- Produces: `StudioCanvas(model:)`, `StudioTransport(model:)`.
- Consumes: all `StylingModel` transport/zoom APIs used by the old `StudioTimeline` (`seek`, `togglePlay`, `addZoom`, `updateZoom`, `resizeZoom`, `deleteZoom`, `setZoomLevel`, `applyTrim`, `currentTime`, `duration`, `isPlaying`, `zooms`).

- [ ] **Step 1: Canvas.** `App/Studio/StudioCanvas.swift`:

```swift
import SwiftUI

/// The preview stage: player floating on the window background with rounded corners,
/// drag/resize overlays on top.
struct StudioCanvas: View {
    @ObservedObject var model: StylingModel

    var body: some View {
        ZStack {
            StudioTheme.windowBG
            ZStack {
                PlayerView(player: model.player)
                WebcamDragOverlay(model: model)
            }
            .aspectRatio(model.canvasSize.width / max(model.canvasSize.height, 1),
                         contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(24)
            if model.processingAudio {
                ProgressView("Processing audio…")
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

Note: `WebcamDragOverlay` must live inside the same aspect-fitted container as the player (as above) so its geometry math still matches the video frame.

- [ ] **Step 2: Transport + timeline.** Copy `App/Styling/StudioTimeline.swift` to `App/Studio/StudioTransport.swift`, rename the top-level view `StudioTransport`, keep ALL gesture/anchor logic (`ZoomDragAnchor`, `ArrowCap`, `beginDrag`, `resizeDrag`, `edgeDrag`, `scrub`, two-click lane creation) byte-identical, and restyle only:
  - Root: `.padding(.horizontal, 16).padding(.vertical, 12).background(StudioTheme.windowBG)` (replace `Color.black.opacity(0.92)`).
  - Replace the `chip` color constant with `StudioTheme.chipBG`; keep the purple/gold gradients as-is (they already match the reference).
  - Control row layout → left / center / right:

```swift
private var controlRow: some View {
    ZStack {
        // Center: time · transport · duration (the reference's focal cluster).
        HStack(spacing: 10) {
            Text(fmt(model.currentTime))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(StudioTheme.textPrimary)
            transport("backward.end.fill") { model.seek(to: trimStart) }
            transport(model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
            transport("forward.end.fill") { model.seek(to: trimEnd) }
            Text(fmt(dur))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(StudioTheme.textSecondary)
        }
        HStack(spacing: 14) {
            // Left: timeline zoom.
            HStack(spacing: 8) {
                Slider(value: $timelineZoom, in: 1...6).frame(width: 130)
                    .tint(StudioTheme.accent)
                Text("\(Int(timelineZoom * 100))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.textSecondary)
                Button { timelineZoom = 1 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(StudioTheme.textSecondary)
                .help("Reset timeline zoom")
            }
            Spacer()
            // Right: Cut.
            Button {
                model.renderSettings.trimEnd = model.currentTime
                model.applyTrim()
            } label: { Label("Cut", systemImage: "scissors") }
                .buttonStyle(ChipButtonStyle())
                .help("Trim the end at the playhead")
        }
    }
}

private func transport(_ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(StudioTheme.textPrimary)
            .frame(width: 44, height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(StudioTheme.chipBG))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(StudioTheme.chipBorder, lineWidth: 1))
    }
    .buttonStyle(.plain)
}
```

  - Play/pause: add `.keyboardShortcut(.space, modifiers: [])` on the play transport button.
  - Zoom editor row (`zoomEditor`): restyle with theme colors (`StudioTheme.textSecondary` labels, `ChipButtonStyle` delete button) — same controls.
  - Ruler/track/pills: keep sizes but soften — `trackH: CGFloat = 44`, corner radius 9 on the video track, ruler text `StudioTheme.textSecondary`.

- [ ] **Step 3: Assemble root.** `StudioRootView` body becomes:

```swift
VStack(spacing: 0) {
    StudioToolbar(model: model)
    HStack(spacing: 0) {
        SidebarRail(selection: $section)
        // panel switch (from Task 8)
        VStack(spacing: 0) {
            StudioCanvas(model: model)
            StudioTransport(model: model)
        }
    }
}
```

Delete `App/Styling/StylingView.swift`, `App/Styling/InspectorView.swift`, `App/Styling/StudioTimeline.swift` (`git rm`).

- [ ] **Step 4: Build + run** — full chrome: rail, panels, canvas, transport, timeline; trim caps, zoom pills, scrubbing, space bar all work; nothing references the deleted views (`grep -rn "StylingView\|InspectorView\|StudioTimeline" App/` returns only StudioTransport internals).
- [ ] **Step 5: Commit** — `git commit -am "feat(studio): canvas + restyled transport/timeline, retire old views"`

---

### Task 10: Final verification + smoke docs

**Files:**
- Modify: `docs/SMOKE.md`

- [ ] **Step 1: Full test suite** — `make test` (all four packages) → PASS.
- [ ] **Step 2: Full app build** — `make build` → succeeds.
- [ ] **Step 3: Manual smoke** (launch the built app): record a short clip → Studio opens with the new chrome → change aspect to 9:16, speed to 1.5×, pick a wallpaper, blur it, tweak camera layout → play (speed + pitch OK, zooms glide with no shake) → undo ×5 / redo ×5 → Cut at playhead → Export → verify the exported file honors aspect/speed/blur/zooms.
- [ ] **Step 4: Document** — append the new-chrome smoke steps (the list above) to `docs/SMOKE.md`.
- [ ] **Step 5: Commit** — `git commit -am "docs: smoke steps for the redesigned studio"`

---

## Self-Review Notes

- Spec coverage: chrome (Tasks 6–9), engine features (1–4), undo (5+7), spring zoom (2), tests (each engine task + 10), smoke (10). Backgrounds use system wallpapers per the amended spec; "Browse all" collapsed into "Pick random"/grid + custom upload (YAGNI — a full browser sheet adds little over the grid).
- Type consistency: `model.canvasSize` (Task 5) consumed by Tasks 8–9; `AspectPreset` cases match `SegmentChips` usage; `ChipButtonStyle`/`SegmentChips`/`PanelSection`/`StudioSlider` defined in Task 6, used in 7–9.
- Known intentional deviations from the screenshot: no Shared/Affiliate/Frames rail items, no intro/outro, no per-interval speed (global only), no "To end" floating chip (it's a tooltip in the reference).
