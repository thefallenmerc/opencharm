import AppKit
import AudioPipeline
import AVFoundation
import CoreImage
import ProjectStore
import RenderCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StylingModel: ObservableObject {
    @Published var renderSettings: RenderSettings { didSet { renderSettingsChanged(old: oldValue) } }
    @Published var audioSettings: AudioSettings { didSet { audioSettingsChanged(old: oldValue) } }
    @Published var processingAudio = false
    @Published var errorMessage: String?
    @Published var showExport = false // Task 19 attaches the sheet
    /// Playhead position and clip length (composition seconds) — drive the Studio timeline.
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    /// True once an edit has been made since the last save. Combined with `savedArchiveURL` to decide
    /// whether closing should prompt to save a portable `.charmproj`.
    @Published var hasUnsavedChanges = false
    @Published var isSaving = false
    /// The `.charmproj` this project was last saved to / opened from (nil = never saved to a chosen
    /// location, e.g. a fresh recording).
    @Published private(set) var savedArchiveURL: URL?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Whether closing/quitting should prompt to save: unsaved edits, or never saved to a location.
    var needsSavePrompt: Bool { savedArchiveURL == nil || hasUnsavedChanges }

    let player = AVPlayer()
    private(set) var package: ProjectPackage
    private(set) var sourceCanvasSize = CGSize(width: 1920, height: 1080)
    /// The output canvas: the recording's size, extended per the aspect preset.
    var canvasSize: CGSize {
        (renderSettings.aspect ?? .auto).canvasSize(for: sourceCanvasSize)
    }
    /// Recorded clicks mapped to normalized screen space, loaded once. Used to seed auto-zooms.
    private(set) var autoZoomClicks: [ClickEvent] = []
    /// All pointer samples (moves + clicks), for focusing zooms, cursor-follow panning, and
    /// drawing the synthetic pointer.
    private(set) var cursorSamples: [CursorSample] = []
    private var videoDebounce: Task<Void, Never>?
    private var audioDebounce: Task<Void, Never>?
    private var saveDebounce: Task<Void, Never>?
    private var timeObserver: Any?
    private var isLoaded = false
    /// New recordings hide the system cursor; the compositor draws this synthetic pointer instead.
    var hasSyntheticCursor: Bool { package.manifest.hidesSystemCursor ?? false }
    private lazy var cursorImage = CursorImage.make()
    private lazy var cursorHandImage = CursorImage.pointingHand()
    /// The full pointer track goes to the builder regardless of the synthetic cursor: it also
    /// drives the zoomed viewport's cursor-follow pan. Drawing is gated by `cursorImage` being
    /// non-nil, so recordings that kept the system cursor never get a second pointer.
    private var cursorTrack: [CursorSample] { cursorSamples }
    /// Cursor inputs for the exporter (mirrors what the preview uses).
    var exportCursorSamples: [CursorSample] { cursorTrack }
    var exportCursorImage: CIImage? { hasSyntheticCursor ? cursorImage : nil }
    var exportCursorHandImage: CIImage? { hasSyntheticCursor ? cursorHandImage : nil }

    init(package: ProjectPackage, savedArchiveURL: URL? = nil) {
        self.package = package
        self.savedArchiveURL = savedArchiveURL
        self.renderSettings = package.manifest.renderSettings
        self.audioSettings = package.manifest.audioSettings
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.currentTime = t.seconds
                self?.skipDeletedSegmentIfNeeded()
            }
        }
        player.publisher(for: \.timeControlStatus)
            .map { $0 == .playing }
            .assign(to: &$isPlaying)
        Task { await initialLoad() }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    private func initialLoad() async {
        autoZoomClicks = ClickTrack.load(package: package)
        cursorSamples = ClickTrack.loadCursor(package: package)
        // Seed the editable timeline zooms from clicks the first time this project is opened.
        if renderSettings.zooms == nil {
            let auto = AutoZoom.segments(clicks: autoZoomClicks,
                                         settings: renderSettings.autoZoom ?? .default)
            renderSettings.zooms = specs(from: auto, manual: false)
        }
        if let track = try? await AVURLAsset(url: package.screenURL)
            .loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            sourceCanvasSize = size
        }
        await rebuildComposition()
        isLoaded = true // edits after this point mark the project dirty (seeding above must not)
    }

    /// Raw or cache-processed audio depending on toggles. forPreview=false is identical today;
    /// kept as a parameter so export always states its intent explicitly.
    ///
    /// Thin `@MainActor` wrapper around the `nonisolated` static below, kept for callers (and
    /// tests) that only need it once the audio cache is already warm — a warm
    /// `AudioCache.processedURL` is just a fast file-existence check. Every hot path that can
    /// hit a COLD cache (`rebuildComposition()`, `rebuildVideoComposition()`, and
    /// `ExportModel.begin()`) must instead call `buildTimeline` directly from a detached task,
    /// never this method: a cache miss runs RNNoise synchronously and can take real time,
    /// which must never block the main actor.
    func timeline(forPreview: Bool) throws -> MediaTimeline {
        try Self.buildTimeline(manifest: package.manifest, packageURL: package.url,
                               cacheDir: package.cacheDir, audioSettings: audioSettings,
                               forPreview: forPreview)
    }

    /// Plain-value variant of `timeline(forPreview:)` with no dependency on `self` or the main
    /// actor, so it can run entirely inside a detached task. `AudioCache.processedURL` can take
    /// real time on a cache miss (RNNoise on minutes of audio) and that must never block the
    /// main actor — which a method isolated to `self` (a `@MainActor` instance) cannot avoid,
    /// since calling it at all requires being on the main actor.
    nonisolated static func buildTimeline(manifest: ProjectManifest, packageURL: URL,
                                          cacheDir: URL, audioSettings: AudioSettings,
                                          forPreview: Bool) throws -> MediaTimeline {
        var audio: [MediaTimeline.AudioTrack] = []
        if let mic = manifest.mic {
            let url = try AudioCache.processedURL(
                for: packageURL.appendingPathComponent(mic.filename),
                cacheDir: cacheDir,
                denoise: audioSettings.noiseRemoval, enhance: audioSettings.voiceEnhance)
            audio.append(.init(url: url, startOffset: mic.startOffset,
                               volume: audioSettings.micVolume))
        }
        if let sys = manifest.systemAudio {
            // System audio never gets voice processing — only volume.
            audio.append(.init(url: packageURL.appendingPathComponent(sys.filename),
                               startOffset: sys.startOffset,
                               volume: audioSettings.systemVolume))
        }
        return MediaTimeline(
            screen: .init(url: packageURL.appendingPathComponent(manifest.screen.filename),
                          startOffset: manifest.screen.startOffset),
            webcam: manifest.webcam.map {
                .init(url: packageURL.appendingPathComponent($0.filename),
                      startOffset: $0.startOffset)
            },
            audio: audio)
    }

    func resolvedBackgroundImage() -> CIImage? {
        guard case .image(let path) = renderSettings.background else { return nil }
        if path.hasPrefix("preset:") {
            let name = String(path.dropFirst("preset:".count))
            guard let url = Bundle.main.url(forResource: name, withExtension: "png")
            else { return nil }
            return CIImage(contentsOf: url)
        }
        return CIImage(contentsOf: URL(fileURLWithPath: path))
    }

    // MARK: Timeline zooms & transport

    var zooms: [ZoomSpec] { renderSettings.zooms ?? [] }

    /// The zoom applied to the preview frame at `t` — the canvas overlay uses it to keep
    /// editing chrome (blur boxes) aligned with the magnified content.
    func zoomState(at t: Double) -> ZoomState {
        ZoomTimeline.state(at: t, segments: zooms.map(\.segment), cursorTrack: cursorSamples)
    }

    // MARK: Privacy blur boxes

    /// Selection is shared by the timeline lane and the canvas overlay: selecting in either
    /// place shows the resize chrome in both.
    @Published var selectedBlurID: String?
    /// Armed by the toolbar "Blur" button; the canvas overlay then turns a drag into a new box.
    @Published var isDrawingBlur = false

    var blurBoxes: [BlurBoxSpec] { renderSettings.blurBoxes ?? [] }

    /// Creates a 2-second box at the playhead over `rect` (normalized content space) and
    /// selects it.
    @discardableResult
    func addBlurBox(rect: CGRect) -> BlurBoxSpec {
        let start = min(max(0, currentTime), max(0, duration - 0.5))
        let end = duration > 0 ? min(duration, start + 2) : start + 2
        let spec = BlurBoxSpec(id: UUID().uuidString, start: start, end: max(end, start + 0.5),
                               rect: rect)
        renderSettings.blurBoxes = (blurBoxes + [spec]).sorted { $0.start < $1.start }
        selectedBlurID = spec.id
        return spec
    }

    func updateBlurBox(_ spec: BlurBoxSpec) {
        guard blurBoxes.contains(where: { $0.id == spec.id }) else { return }
        renderSettings.blurBoxes = blurBoxes.map { $0.id == spec.id ? spec : $0 }
            .sorted { $0.start < $1.start }
    }

    /// Resizes a box's time span (composition seconds), clamped to a minimum length.
    func resizeBlurBox(_ spec: BlurBoxSpec, start: Double? = nil, end: Double? = nil) {
        let minLen = 0.2
        var s = spec
        if let start { s.start = min(max(0, start), s.end - minLen) }
        if let end { s.end = max(min(max(duration, minLen), end), s.start + minLen) }
        updateBlurBox(s)
    }

    func deleteBlurBox(_ id: String) {
        renderSettings.blurBoxes = blurBoxes.filter { $0.id != id }
        if selectedBlurID == id { selectedBlurID = nil }
    }

    /// Updates a box's corner radius and/or blur intensity; a `nil` param leaves that property
    /// unchanged (pass only the ones you're editing).
    func setBlurStyle(_ id: String, cornerRadius: Double? = nil, intensity: Double? = nil) {
        guard var spec = blurBoxes.first(where: { $0.id == id }) else { return }
        if let cornerRadius { spec.cornerRadius = cornerRadius }
        if let intensity { spec.intensity = intensity }
        updateBlurBox(spec)
    }

    /// Select (or deselect with nil). Selecting seeks into the box's time range when the
    /// playhead is outside it, so the blur is visible on the preview while editing.
    func selectBlur(_ id: String?) {
        selectedBlurID = id
        guard let id, let spec = blurBoxes.first(where: { $0.id == id }) else { return }
        if currentTime < spec.start || currentTime > spec.end {
            seek(to: spec.start + min(0.05, (spec.end - spec.start) / 2))
        }
    }

    private func specs(from segments: [ZoomSegment], manual: Bool) -> [ZoomSpec] {
        segments.map {
            ZoomSpec(id: UUID().uuidString, start: $0.start, end: $0.end,
                     easeIn: $0.easeIn, easeOut: $0.easeOut, focus: $0.focus,
                     scale: $0.scale, manual: manual, focusKeys: $0.focusKeys)
        }
    }

    /// Resizes a zoom by setting a new start and/or end (composition seconds), clamped to a minimum
    /// length. Keeps the pan keyframes at their absolute times; eases are capped to fit.
    func resizeZoom(_ spec: ZoomSpec, start: Double? = nil, end: Double? = nil) {
        let minLen = 0.3
        var s = spec
        if let start { s.start = min(max(0, start), s.end - minLen) }
        if let end { s.end = max(min(max(duration, minLen), end), s.start + minLen) }
        let d = s.end - s.start
        s.easeIn = min(s.easeIn, d / 2)
        s.easeOut = min(s.easeOut, d / 2)
        updateZoom(s)
    }

    /// Centroid of the cursor path within [start,end] (falls back to the last known position, then
    /// the centre) — a manual zoom's focus.
    func focus(in start: Double, end: Double) -> CGPoint {
        let lo = min(start, end), hi = max(start, end)
        var pts = cursorSamples.filter { $0.time >= lo && $0.time <= hi }.map(\.point)
        if pts.isEmpty, let last = cursorSamples.last(where: { $0.time <= hi })?.point { pts = [last] }
        guard !pts.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
    }

    /// Adds a manual zoom spanning [start,end], focused on the cursor location over that span.
    @discardableResult
    func addZoom(start: Double, end: Double) -> ZoomSpec {
        let lo = max(0, min(start, end)), hi = min(max(duration, 0.3), max(start, end))
        let spec = ZoomSpec(id: UUID().uuidString, start: lo, end: max(lo + 0.3, hi),
                            easeIn: 0.4, easeOut: 0.5, focus: focus(in: lo, end: hi),
                            scale: renderSettings.autoZoom?.level ?? 2.0, manual: true)
        renderSettings.zooms = (zooms + [spec]).sorted { $0.start < $1.start }
        return spec
    }

    func updateZoom(_ spec: ZoomSpec) {
        guard zooms.contains(where: { $0.id == spec.id }) else { return }
        var s = spec
        s.manual = true // an edit protects it from click-regeneration
        renderSettings.zooms = zooms.map { $0.id == s.id ? s : $0 }.sorted { $0.start < $1.start }
    }

    func setZoomLevel(_ id: String, scale: Double) {
        guard var s = zooms.first(where: { $0.id == id }) else { return }
        s.scale = min(3, max(1.5, scale))
        updateZoom(s)
    }

    func deleteZoom(_ id: String) {
        renderSettings.zooms = zooms.filter { $0.id != id }
    }

    /// Re-seeds the click-derived (non-manual) zooms from the current auto-zoom settings, keeping any
    /// manual ones. Called when the auto-zoom toggle/level/speed change or on explicit regenerate.
    func regenerateAutoZooms() {
        let manual = zooms.filter(\.manual)
        let auto = (renderSettings.autoZoom?.enabled ?? false)
            ? specs(from: AutoZoom.segments(clicks: autoZoomClicks,
                                            settings: renderSettings.autoZoom ?? .default),
                    manual: false)
            : []
        renderSettings.zooms = (manual + auto).sorted { $0.start < $1.start }
    }

    // MARK: Split segments (Cut)

    /// One timeline segment between split boundaries. `deleted` segments are skipped in preview
    /// and removed on export.
    struct TimelineSegment: Identifiable, Equatable {
        let id: Int
        let start: Double
        let end: Double
        let deleted: Bool
    }

    private var normalizedCuts: [CutRange] {
        CutClock.normalized(renderSettings.cuts ?? [], duration: max(duration, 0.1))
    }

    /// Segments between consecutive split boundaries, in timeline order.
    var timelineSegments: [TimelineSegment] {
        let dur = max(duration, 0.1)
        let bounds = ([0.0] + (renderSettings.splits ?? []).filter { $0 > 0.05 && $0 < dur - 0.05 }
            + [dur]).sorted()
        let cuts = normalizedCuts
        return zip(bounds, bounds.dropFirst()).enumerated().compactMap { i, pair in
            let (a, b) = pair
            guard b - a > 0.05 else { return nil }
            let mid = (a + b) / 2
            let deleted = cuts.contains { mid >= $0.start && mid <= $0.end }
            return TimelineSegment(id: i, start: a, end: b, deleted: deleted)
        }
    }

    /// Splits the video at the playhead (the timeline's scissor button).
    func splitAtPlayhead() {
        let t = currentTime
        guard t > 0.1, t < duration - 0.1 else { return }
        var splits = renderSettings.splits ?? []
        guard !splits.contains(where: { abs($0 - t) < 0.05 }) else { return }
        splits.append(t)
        renderSettings.splits = splits.sorted()
    }

    /// Deletes a kept segment / restores a deleted one.
    func toggleSegmentDeleted(_ segment: TimelineSegment) {
        var cuts = normalizedCuts
        if segment.deleted {
            // Restore: subtract this segment's range from any overlapping cut.
            cuts = cuts.flatMap { cut -> [CutRange] in
                guard cut.start < segment.end, cut.end > segment.start else { return [cut] }
                var pieces: [CutRange] = []
                if cut.start < segment.start { pieces.append(CutRange(start: cut.start, end: segment.start)) }
                if cut.end > segment.end { pieces.append(CutRange(start: segment.end, end: cut.end)) }
                return pieces
            }
        } else {
            cuts.append(CutRange(start: segment.start, end: segment.end))
        }
        renderSettings.cuts = CutClock.normalized(cuts, duration: max(duration, 0.1))
    }

    /// While playing, jump over deleted segments (export removes them for real; the preview
    /// composition keeps the full clip so the timeline clock stays the original one).
    private func skipDeletedSegmentIfNeeded() {
        guard isPlaying else { return }
        if let cut = normalizedCuts.first(where: { currentTime >= $0.start && currentTime < $0.end - 0.05 }) {
            seek(to: cut.end)
        }
    }

    /// Seeks the player, clamped to the trimmed range when set.
    func seek(to time: Double) {
        let lo = renderSettings.trimStart ?? 0
        let hi = renderSettings.trimEnd ?? duration
        let t = min(max(time, lo), max(lo, hi))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
            return
        }
        // Play from the top when the playhead is parked at (or past) the end of the
        // playable range — otherwise play resumes into the stop point and does nothing.
        let end = renderSettings.trimEnd ?? duration
        if end > 0, currentTime >= end - 0.05 {
            seek(to: renderSettings.trimStart ?? 0)
        }
        player.play()
    }

    // MARK: Save as portable .charmproj

    var projectName: String { (savedArchiveURL ?? package.url).deletingPathExtension().lastPathComponent }

    /// Saves to the existing archive location if any, otherwise prompts for one. Returns whether a
    /// file was written (false if the user cancelled the save panel or it failed).
    @discardableResult
    func saveProject() async -> Bool {
        if let url = savedArchiveURL { return await save(to: url) }
        return await saveProjectAs()
    }

    @discardableResult
    func saveProjectAs() async -> Bool {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: "charmproj") { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = projectName + ".charmproj"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return await save(to: url)
    }

    private func save(to dest: URL) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        // Flush the latest settings into the working-copy manifest so the archive is current.
        package.manifest.renderSettings = renderSettings
        package.manifest.audioSettings = audioSettings
        try? package.saveManifest()
        let src = package.url
        do {
            try await Task.detached { try ProjectArchive.write(packageURL: src, to: dest) }.value
            savedArchiveURL = dest
            hasUnsavedChanges = false
            return true
        } catch {
            errorMessage = "Couldn't save project: \(error.localizedDescription)"
            return false
        }
    }

    /// Bounds preview playback to the trimmed range (stops at trimEnd). Export applies the real cut.
    func applyTrim() {
        guard let item = player.currentItem else { return }
        if let end = renderSettings.trimEnd {
            item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        } else {
            item.forwardPlaybackEndTime = .invalid
        }
    }

    func rebuildComposition() async {
        processingAudio = true
        defer { processingAudio = false }
        do {
            // Snapshot everything the detached task needs as plain (Sendable) values — it must
            // not touch `self`, a `@MainActor` instance, or cache generation (which can take
            // real time on a cache miss) would hop back onto the main actor to reach it.
            let manifest = package.manifest
            let packageURL = package.url
            let cacheDir = package.cacheDir
            let audio = audioSettings
            let settings = renderSettings
            let canvas = canvasSize
            let bg = resolvedBackgroundImage()
            let clicks = autoZoomClicks
            let timeline = try await Task.detached {
                try Self.buildTimeline(manifest: manifest, packageURL: packageURL,
                                       cacheDir: cacheDir, audioSettings: audio,
                                       forPreview: true)
            }.value
            // A newer audio-settings change may have superseded us while we were off doing
            // cache generation — don't clobber the player with a stale result.
            guard !Task.isCancelled else { return }
            let built = try await ProjectCompositionBuilder.build(
                timeline: timeline, settings: settings, canvasSize: canvas,
                backgroundImage: bg, clicks: clicks,
                cursorSamples: cursorTrack, cursorImage: exportCursorImage,
                cursorHandImage: exportCursorHandImage)
            guard !Task.isCancelled else { return }
            duration = built.composition.duration.seconds
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            // Preview speed rides AVPlayer's rate (the composition stays 1x); keep the voice's
            // pitch when it does.
            item.audioTimePitchAlgorithm = .timeDomain
            player.defaultRate = Float(renderSettings.playbackSpeed ?? 1)
            let time = player.currentTime()
            player.replaceCurrentItem(with: item)
            applyTrim()
            if time.isValid, time.seconds > 0 {
                await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } catch {
            errorMessage = "Preview failed: \(error.localizedDescription)"
        }
    }

    func rebuildVideoComposition() {
        videoDebounce?.cancel()
        videoDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled, let item = player.currentItem else { return }
            do {
                // Same reasoning as rebuildComposition(): a cold `AudioCache` entry runs
                // RNNoise synchronously and can take real time, so `buildTimeline` must run
                // off the main actor even though only render (not audio) settings changed
                // here — the cache can still be cold the first time this fires. Snapshot
                // everything the detached task needs as plain (Sendable) values.
                let manifest = package.manifest
                let packageURL = package.url
                let cacheDir = package.cacheDir
                let audio = audioSettings
                let settings = renderSettings
                let canvas = canvasSize
                let bg = resolvedBackgroundImage()
                let clicks = autoZoomClicks
                let timeline = try await Task.detached {
                    try Self.buildTimeline(manifest: manifest, packageURL: packageURL,
                                           cacheDir: cacheDir, audioSettings: audio,
                                           forPreview: true)
                }.value
                guard !Task.isCancelled else { return }
                let built = try await ProjectCompositionBuilder.build(
                    timeline: timeline, settings: settings, canvasSize: canvas,
                    backgroundImage: bg, clicks: clicks,
                    cursorSamples: cursorTrack, cursorImage: exportCursorImage,
                cursorHandImage: exportCursorHandImage)
                guard !Task.isCancelled else { return }
                item.videoComposition = built.videoComposition
                if player.rate == 0 { // refresh the paused frame
                    await player.seek(to: player.currentTime(),
                                      toleranceBefore: .zero, toleranceAfter: .zero)
                }
            } catch { errorMessage = "Preview failed: \(error.localizedDescription)" }
        }
    }

    private func renderSettingsChanged(old: RenderSettings) {
        if isLoaded, old != renderSettings {
            hasUnsavedChanges = true
            if !isRestoring { recordUndo(EditSnapshot(render: old, audio: audioSettings)) }
        }
        // Keep preview speed live: defaultRate covers the next play; an in-flight playback
        // re-rates immediately.
        let rate = Float(renderSettings.playbackSpeed ?? 1)
        player.defaultRate = rate
        if isPlaying, abs(player.rate - rate) > 0.001 { player.rate = rate }
        if old.aspect != renderSettings.aspect {
            // A render-size change doesn't take effect on a live AVPlayerItem — swapping just the
            // videoComposition leaves the player displaying at the old aspect (cropped/stretched).
            // The item must be rebuilt around the new canvas.
            audioDebounce?.cancel()
            audioDebounce = Task { [weak self] in await self?.rebuildComposition() }
        } else {
            rebuildVideoComposition()
        }
        persist()
    }

    private func audioSettingsChanged(old: AudioSettings) {
        if isLoaded, old != audioSettings {
            hasUnsavedChanges = true
            if !isRestoring { recordUndo(EditSnapshot(render: renderSettings, audio: old)) }
        }
        audioDebounce?.cancel()
        audioDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            await self.rebuildComposition()
        }
        persist()
    }

    // MARK: Undo/redo

    /// Everything an edit can touch, captured as one value. Timeline zooms and trim live inside
    /// `RenderSettings`, so this pair covers the whole editable state.
    private struct EditSnapshot {
        var render: RenderSettings
        var audio: AudioSettings
    }

    private let editUndo = UndoManager()
    private var isRestoring = false
    private var lastUndoRegistration = Date.distantPast

    /// One undo record per discrete edit. Continuous slider drags coalesce: registrations within
    /// 0.8 s of the previous one extend that record (the drag's origin snapshot stays on the
    /// stack) instead of stacking one per tick.
    private func recordUndo(_ old: EditSnapshot) {
        let now = Date()
        defer { lastUndoRegistration = now }
        if now.timeIntervalSince(lastUndoRegistration) < 0.8 { refreshUndoFlags(); return }
        editUndo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(old) }
        }
        refreshUndoFlags()
    }

    /// Applies a snapshot and registers the inverse — UndoManager routes that registration to the
    /// redo stack automatically while undoing (and back again while redoing).
    private func restore(_ snap: EditSnapshot) {
        let current = EditSnapshot(render: renderSettings, audio: audioSettings)
        isRestoring = true
        if renderSettings != snap.render { renderSettings = snap.render }
        if audioSettings != snap.audio { audioSettings = snap.audio }
        isRestoring = false
        hasUnsavedChanges = true
        editUndo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(current) }
        }
        refreshUndoFlags()
    }

    func undoEdit() {
        lastUndoRegistration = .distantPast
        editUndo.undo()
        refreshUndoFlags()
    }

    func redoEdit() {
        lastUndoRegistration = .distantPast
        editUndo.redo()
        refreshUndoFlags()
    }

    private func refreshUndoFlags() {
        canUndo = editUndo.canUndo
        canRedo = editUndo.canRedo
    }

    private func persist() {
        saveDebounce?.cancel()
        saveDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            package.manifest.renderSettings = renderSettings
            package.manifest.audioSettings = audioSettings
            try? package.saveManifest()
        }
    }
}
