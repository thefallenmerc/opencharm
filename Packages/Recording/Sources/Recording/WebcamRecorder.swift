import AVFoundation

public final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var writer: TrackWriter?
    private let outputURL: URL
    private let queue = DispatchQueue(label: "webcamrecorder")
    public let previewLayer: AVCaptureVideoPreviewLayer

    public var firstPTS: Double? { writer?.firstPTSSeconds }

    public init(deviceID: String, outputURL: URL) throws {
        self.outputURL = outputURL
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw RecordingError.sourceUnavailable
        }
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingError.sourceUnavailable }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { throw RecordingError.sourceUnavailable }
        session.addOutput(output)
        session.commitConfiguration()
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    public func start() async throws {
        let dims = (session.inputs.first as? AVCaptureDeviceInput).map {
            CMVideoFormatDescriptionGetDimensions($0.device.activeFormat.formatDescription)
        } ?? .init(width: 1280, height: 720)
        writer = try TrackWriter(url: outputURL,
                                 kind: .hevcVideo(size: CGSize(width: Int(dims.width),
                                                               height: Int(dims.height)),
                                                  fps: 30))
        session.startRunning()
    }

    public func stop() async throws {
        session.stopRunning()
        try await writer?.finish()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        writer?.append(Self.rebaseToHostClock(sampleBuffer, session: session))
    }

    /// Converts session-clock PTS to host clock so all tracks share one timeline.
    static func rebaseToHostClock(_ sampleBuffer: CMSampleBuffer,
                                  session: AVCaptureSession) -> CMSampleBuffer {
        guard let sessionClock = session.synchronizationClock else { return sampleBuffer }
        let hostClock = CMClockGetHostTimeClock()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostPTS = CMSyncConvertTime(pts, from: sessionClock, to: hostClock)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: hostPTS,
                                        decodeTimeStamp: .invalid)
        var rebased: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing,
                                              sampleBufferOut: &rebased)
        return rebased ?? sampleBuffer
    }
}
