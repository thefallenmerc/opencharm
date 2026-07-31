import AVFoundation

public final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private var writer: TrackWriter?
    private let outputURL: URL
    private let queue = DispatchQueue(label: "micrecorder")

    public var firstPTS: Double? { writer?.firstPTSSeconds }

    public init(deviceID: String, outputURL: URL) throws {
        self.outputURL = outputURL
        super.init()
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw RecordingError.sourceUnavailable
        }
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingError.sourceUnavailable }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else { throw RecordingError.sourceUnavailable }
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    public func start() throws {
        writer = try TrackWriter(url: outputURL, kind: .passthroughAudio)
        session.startRunning()
    }

    public func stop() async throws {
        session.stopRunning()
        try await writer?.finish()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        let rebased = WebcamRecorder.rebaseToHostClock(sampleBuffer, session: session)
        // AVCaptureAudioDataOutput delivers non-interleaved (planar) linear PCM, same as
        // ScreenCaptureKit's system-audio output (see ScreenRecorder.stream(_:didOutputSampleBuffer:of:)).
        // TrackWriter's `.passthroughAudio` writer adds its input with `outputSettings: nil`,
        // which rejects a non-interleaved source via `canAdd`. Re-pack to interleaved before
        // handing off, preserving the (already host-clock-rebased) presentation time.
        if let interleaved = ScreenRecorder.interleaved(rebased) {
            writer?.append(interleaved)
        }
    }
}
