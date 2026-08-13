import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ProjectStore
import ScreenCaptureKit

@MainActor
public final class RecordingEngine: ObservableObject {
    public enum State: Equatable { case idle, recording(startedAt: Date), stopping }

    @Published public private(set) var state: State = .idle
    public private(set) var webcamPreviewLayer: AVCaptureVideoPreviewLayer?

    private var package: ProjectPackage?
    private var screen: ScreenRecorder?
    private var webcam: WebcamRecorder?
    private var mic: MicRecorder?
    private var events: EventLogger?
    private var offsetsTask: Task<Void, Never>?
    /// Whether the current recording is expected to produce a system-audio track. Derived
    /// from configuration at `start` time — must NOT be derived from `pkg.manifest.systemAudio`
    /// (that value is only ever set by `writeOffsetsIfComplete` itself, so gating completeness
    /// on it would be a tautology that always reads as "not yet active" until the very write
    /// that's supposed to be gated).
    private var capturesSystemAudio = false
    /// Global desktop rect the screen video covers at start, persisted to the manifest for
    /// auto-zoom click mapping. For window captures this is the window's frame at start;
    /// movement afterwards is tracked by `rectTask` as "rect" events in the event log.
    private var captureGlobalRect: CGRect?
    private var rectTask: Task<Void, Never>?

    public init() {}

    /// The global (top-left, points) rect a capture source covers. Matches `EventLogger`'s
    /// global desktop coordinate space so recorded clicks map into the screen video.
    static func globalCaptureRect(for source: RecordingConfiguration.Source) -> CGRect? {
        switch source {
        case .display(let id):
            return CGDisplayBounds(id)
        case .area(let displayID, let rect):
            let b = CGDisplayBounds(displayID)
            return CGRect(x: b.origin.x + rect.origin.x, y: b.origin.y + rect.origin.y,
                          width: rect.width, height: rect.height)
        case .window(let window):
            // The frame at start; `rectTask` logs "rect" events if the window moves later.
            return window.frame
        }
    }

    /// Current global (top-left, points) bounds of an on-screen window, or nil once it's gone.
    static func currentWindowBounds(windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let boundsDict = info.first?[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        return bounds
    }

    public func start(configuration: RecordingConfiguration, projectURL: URL) async throws {
        guard case .idle = state else { return }
        let pkg = try ProjectPackage.create(at: projectURL)
        try pkg.markRecordingStarted()

        let screen = ScreenRecorder(
            configuration: configuration,
            videoURL: pkg.screenURL,
            systemAudioURL: configuration.capturesSystemAudio ? pkg.systemAudioURL : nil)
        var webcam: WebcamRecorder?
        var mic: MicRecorder?
        let events = EventLogger(fileURL: pkg.eventsURL)

        do {
            if let camID = configuration.webcamDeviceID {
                webcam = try WebcamRecorder(deviceID: camID, outputURL: pkg.webcamURL)
            }
            if let micID = configuration.micDeviceID {
                mic = try MicRecorder(deviceID: micID, outputURL: pkg.micURL)
            }
            try await screen.start()
            try await webcam?.start()
            try mic?.start()
            events.start()
        } catch {
            // A later source failed after an earlier one already started (e.g. webcam
            // fails after screen's SCStream is live): stop whatever did start so nothing
            // is orphaned, drop the lock so this isn't mistaken for an interrupted
            // recording, and leave the engine usable again.
            try? await screen.stop()
            try? await webcam?.stop()
            try? await mic?.stop()
            try? pkg.markRecordingFinished()
            state = .idle
            throw error
        }

        self.package = pkg
        self.screen = screen
        self.webcam = webcam
        self.mic = mic
        self.events = events
        self.capturesSystemAudio = configuration.capturesSystemAudio
        self.captureGlobalRect = Self.globalCaptureRect(for: configuration.source)
        self.webcamPreviewLayer = webcam?.previewLayer
        state = .recording(startedAt: Date())

        // Window captures follow the window wherever it goes, so click positions only make
        // sense relative to where the window was *at that moment*. Poll its bounds and log a
        // "rect" event whenever it moves or resizes; ClickTrack replays these to map clicks.
        if case .window(let scWindow) = configuration.source {
            let windowID = scWindow.windowID
            var lastRect = captureGlobalRect
            rectTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, case .recording = self.state else { return }
                    guard let bounds = Self.currentWindowBounds(windowID: windowID),
                          bounds != lastRect else { continue }
                    lastRect = bounds
                    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    self.events?.log(LoggedEvent(t: now, x: bounds.minX, y: bounds.minY,
                                                 type: "rect",
                                                 w: bounds.width, h: bounds.height))
                }
            }
        }

        // Persist offsets as soon as every active source has produced a first sample.
        offsetsTask = Task { [weak self] in
            for _ in 0..<25 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, case .recording = self.state else { return }
                if self.writeOffsetsIfComplete() { return }
            }
            _ = self?.writeOffsetsIfComplete()
        }
    }

    /// Returns true once all active tracks had a firstPTS and the manifest was saved.
    @discardableResult
    private func writeOffsetsIfComplete() -> Bool {
        guard var pkg = package, let screen else { return false }
        guard let videoPTS = screen.videoFirstPTS,
              (webcam == nil || webcam?.firstPTS != nil),
              (mic == nil || mic?.firstPTS != nil),
              (!capturesSystemAudio || screen.audioFirstPTS != nil) else { return false }

        var candidates = [videoPTS]
        [webcam?.firstPTS, mic?.firstPTS, screen.audioFirstPTS]
            .compactMap { $0 }.forEach { candidates.append($0) }
        let epoch = candidates.min()!

        pkg.manifest.screen = TrackRef(filename: "screen.mov", startOffset: videoPTS - epoch)
        if let p = webcam?.firstPTS {
            pkg.manifest.webcam = TrackRef(filename: "webcam.mov", startOffset: p - epoch)
        }
        if let p = mic?.firstPTS {
            pkg.manifest.mic = TrackRef(filename: "mic.caf", startOffset: p - epoch)
        }
        if let p = screen.audioFirstPTS {
            pkg.manifest.systemAudio = TrackRef(filename: "system.caf", startOffset: p - epoch)
        }
        pkg.manifest.captureRect = captureGlobalRect
        pkg.manifest.hidesSystemCursor = true // capture hides the cursor; the editor draws its own
        try? pkg.saveManifest()
        package = pkg
        events?.epoch = epoch
        return true
    }

    public func stop() async throws -> ProjectPackage {
        guard case .recording = state, var pkg = package else {
            throw RecordingError.sourceUnavailable
        }
        state = .stopping
        offsetsTask?.cancel()
        rectTask?.cancel()
        rectTask = nil

        // Best-effort every step: a failure partway through (any recorder's stop,
        // finalize, or manifest save) must not leave the engine stuck in `.stopping`
        // or skip writing whatever crash-safe artifacts are already available. Collect
        // the first error and rethrow it only after the full teardown/finalize path has
        // run, so the caller still gets a usable package back on the happy path and the
        // engine is always left in `.idle`.
        var firstError: Error?
        func record(_ error: Error) { if firstError == nil { firstError = error } }

        do { try await screen?.stop() } catch { record(error) }
        do { try await webcam?.stop() } catch { record(error) }
        do { try await mic?.stop() } catch { record(error) }

        writeOffsetsIfComplete()
        pkg = package ?? pkg // refreshed by writeOffsetsIfComplete when it succeeded

        do {
            if let events, let epoch = events.epoch {
                try events.finalize(epoch: epoch)
            } else {
                try events?.finalize(epoch: 0)
            }
        } catch { record(error) }

        do { try pkg.markRecordingFinished() } catch { record(error) }
        do { try pkg.saveManifest() } catch { record(error) }

        (screen, webcam, mic, events, webcamPreviewLayer) = (nil, nil, nil, nil, nil)
        package = nil
        state = .idle

        if let firstError { throw firstError }
        return pkg
    }
}
