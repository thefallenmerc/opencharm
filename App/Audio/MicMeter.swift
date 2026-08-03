import AVFoundation
import Combine

/// Runs a lightweight idle audio-capture session on the selected microphone purely to surface a
/// live input level (0…1) for the dock's mic meter — a visible "we're listening" cue. Stopped while
/// recording (the RecordingEngine owns the device then) and whenever the mic is toggled off.
@MainActor
final class MicMeter: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published private(set) var level: Double = 0

    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "micmeter")

    /// Starts metering `deviceID` (nil = default mic). No-op degradation if the device can't open.
    func start(deviceID: String?) {
        stop()
        guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) })
            ?? AVCaptureDevice.default(for: .audio),
            let input = try? AVCaptureDeviceInput(device: device) else { return }
        let s = AVCaptureSession()
        s.beginConfiguration()
        guard s.canAddInput(input) else { s.commitConfiguration(); return }
        s.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(output) else { s.commitConfiguration(); return }
        s.addOutput(output)
        s.commitConfiguration()
        session = s
        Task.detached { s.startRunning() } // blocking; keep off the main actor
    }

    func stop() {
        session?.stopRunning()
        session = nil
        if level != 0 { level = 0 }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // The system computes per-channel power for an audio data output's connection; map dBFS
        // (~-55 quiet … 0 max) to 0…1 so ordinary speech gives a lively fill.
        let power = connection.audioChannels.first?.averagePowerLevel ?? -160
        let norm = min(1, max(0, (Double(power) + 55) / 55))
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Fast attack, slower release: responsive to speech, but not jittery on the way down.
            level = norm > level ? norm : level * 0.8 + norm * 0.2
        }
    }
}
