import AVFoundation
import Foundation
import ProjectStore

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

    public init() {}

    public func start(configuration: RecordingConfiguration, projectURL: URL) async throws {
        guard case .idle = state else { return }
        var pkg = try ProjectPackage.create(at: projectURL)
        try pkg.markRecordingStarted()

        let screen = ScreenRecorder(
            configuration: configuration,
            videoURL: pkg.screenURL,
            systemAudioURL: configuration.capturesSystemAudio ? pkg.systemAudioURL : nil)
        var webcam: WebcamRecorder?
        if let camID = configuration.webcamDeviceID {
            webcam = try WebcamRecorder(deviceID: camID, outputURL: pkg.webcamURL)
        }
        var mic: MicRecorder?
        if let micID = configuration.micDeviceID {
            mic = try MicRecorder(deviceID: micID, outputURL: pkg.micURL)
        }
        let events = EventLogger(fileURL: pkg.eventsURL)

        try await screen.start()
        try await webcam?.start()
        try mic?.start()
        events.start()

        self.package = pkg
        self.screen = screen
        self.webcam = webcam
        self.mic = mic
        self.events = events
        self.webcamPreviewLayer = webcam?.previewLayer
        state = .recording(startedAt: Date())

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
        let sysActive = pkg.manifest.systemAudio != nil || screen.audioFirstPTS != nil
        guard let videoPTS = screen.videoFirstPTS,
              (webcam == nil || webcam?.firstPTS != nil),
              (mic == nil || mic?.firstPTS != nil),
              (!sysActive || screen.audioFirstPTS != nil) else { return false }

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
        try await screen?.stop()
        try await webcam?.stop()
        try await mic?.stop()
        writeOffsetsIfComplete()
        pkg = package! // refreshed by writeOffsetsIfComplete
        if let events, let epoch = events.epoch {
            try events.finalize(epoch: epoch)
        } else {
            try events?.finalize(epoch: 0)
        }
        try pkg.markRecordingFinished()
        try pkg.saveManifest()

        (screen, webcam, mic, events, webcamPreviewLayer) = (nil, nil, nil, nil, nil)
        package = nil
        state = .idle
        return pkg
    }
}
