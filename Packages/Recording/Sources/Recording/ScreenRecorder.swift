import AVFoundation
import AudioToolbox
import ScreenCaptureKit

public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let configuration: RecordingConfiguration
    private let videoURL: URL
    private let systemAudioURL: URL?
    private var stream: SCStream?
    private var videoWriter: TrackWriter?
    private var audioWriter: TrackWriter?
    private let sampleQueue = DispatchQueue(label: "screenrecorder.samples")
    public private(set) var capturePixelSize: CGSize = .zero

    public var videoFirstPTS: Double? { videoWriter?.firstPTSSeconds }
    public var audioFirstPTS: Double? { audioWriter?.firstPTSSeconds }

    public init(configuration: RecordingConfiguration, videoURL: URL, systemAudioURL: URL?) {
        self.configuration = configuration
        self.videoURL = videoURL
        self.systemAudioURL = systemAudioURL
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let excluded = content.windows.filter {
            configuration.excludedWindowNumbers.contains(Int($0.windowID))
        }

        let filter: SCContentFilter
        let streamConfig = SCStreamConfiguration()
        switch configuration.source {
        case .display(let id), .area(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecordingError.sourceUnavailable
            }
            // Exclude the whole app, not just today's known window numbers: the recorder
            // panel, countdown overlay, and area-selector window can each open and close at
            // any point during the recording, and `excludedWindowNumbers` is only a snapshot
            // taken here at start() — so a window opened afterward (e.g. the panel reopened
            // in the recording's final seconds) would otherwise slip into frame.
            if let bundleID = Bundle.main.bundleIdentifier,
               let ownApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                filter = SCContentFilter(display: display, excludingApplications: [ownApp],
                                         exceptingWindows: [])
            } else {
                // No bundle identifier (e.g. `swift test`, which doesn't run inside an app
                // bundle) or our app isn't listed in `content.applications` — fall back to
                // the window-number snapshot so the gated integration test still works.
                filter = SCContentFilter(display: display, excludingWindows: excluded)
            }
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let scale = CGFloat(filter.pointPixelScale)
        if case .area(_, let rect) = configuration.source {
            streamConfig.sourceRect = rect // points, top-left origin of the filtered display
            capturePixelSize = CGSize(width: (rect.width * scale).rounded(.down),
                                      height: (rect.height * scale).rounded(.down))
        } else {
            capturePixelSize = CGSize(width: (filter.contentRect.width * scale).rounded(.down),
                                      height: (filter.contentRect.height * scale).rounded(.down))
        }
        // Even dimensions for HEVC.
        capturePixelSize = CGSize(width: capturePixelSize.width - capturePixelSize.width.truncatingRemainder(dividingBy: 2),
                                  height: capturePixelSize.height - capturePixelSize.height.truncatingRemainder(dividingBy: 2))
        streamConfig.width = Int(capturePixelSize.width)
        streamConfig.height = Int(capturePixelSize.height)
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = false // the editor draws its own (bigger) pointer from the event track
        streamConfig.queueDepth = 8
        if systemAudioURL != nil, configuration.capturesSystemAudio {
            streamConfig.capturesAudio = true
            streamConfig.sampleRate = 48_000
            streamConfig.channelCount = 2
        }

        videoWriter = try TrackWriter(url: videoURL,
                                      kind: .hevcVideo(size: capturePixelSize, fps: configuration.fps))
        if let systemAudioURL, configuration.capturesSystemAudio {
            audioWriter = try TrackWriter(url: systemAudioURL, kind: .passthroughAudio)
        }

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if streamConfig.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async throws {
        try? await stream?.stopCapture()
        stream = nil
        try await videoWriter?.finish()
        try await audioWriter?.finish()
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Only complete frames carry image data.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                      sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  statusRaw == SCFrameStatus.complete.rawValue,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            videoWriter?.append(sampleBuffer)
        case .audio:
            // ScreenCaptureKit delivers system audio as non-interleaved (planar) linear PCM.
            // `TrackWriter`'s `.passthroughAudio` writer adds its input with `outputSettings:
            // nil` (verified empirically: `AVAssetWriterInput.canAdd` rejects a non-interleaved
            // source format regardless of container — .caf or .wav — while an interleaved
            // source of the same sample rate/channel count/bit depth is accepted). Re-pack to
            // interleaved before handing off, preserving the original presentation time.
            if let interleaved = Self.interleaved(sampleBuffer) {
                audioWriter?.append(interleaved)
            }
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Surfaced via stop(); writers keep whatever was written (fragmented).
    }

    /// Converts a non-interleaved linear-PCM `CMSampleBuffer` (ScreenCaptureKit's system-audio
    /// delivery format) into an interleaved one with the same sample rate, channel count, bit
    /// depth, and presentation time. Non-PCM, already-interleaved, or non-Float32 buffers pass
    /// through unchanged — the reinterleave path below reads raw memory as `Float`, so anything
    /// that isn't confirmed 32-bit float PCM must fall through here rather than risk an
    /// out-of-bounds read. Returns `nil` only on an unexpected CoreMedia/CoreAudio failure.
    static func interleaved(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let sourceASBD = asbdPointer.pointee
        guard sourceASBD.mFormatID == kAudioFormatLinearPCM,
              sourceASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
              sourceASBD.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              sourceASBD.mBitsPerChannel == 32 else {
            return sampleBuffer
        }

        let channelCount = Int(sourceASBD.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channelCount > 0, frameCount > 0 else { return nil }

        let listPointer = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { listPointer.unsafeMutablePointer.deallocate() }
        var retainedBlockBuffer: CMBlockBuffer?
        let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer)
        guard listStatus == noErr else { return nil }

        var interleavedSamples = [Float](repeating: 0, count: frameCount * channelCount)
        for (channelIndex, buffer) in listPointer.enumerated() {
            guard let channelData = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frameCount {
                interleavedSamples[frame * channelCount + channelIndex] = channelData[frame]
            }
        }

        let byteCount = frameCount * channelCount * MemoryLayout<Float>.size
        var newBlockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &newBlockBuffer)
        guard blockStatus == kCMBlockBufferNoErr, let newBlockBuffer else { return nil }
        let replaceStatus = interleavedSamples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: newBlockBuffer,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var interleavedASBD = AudioStreamBasicDescription(
            mSampleRate: sourceASBD.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * 4), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * 4), mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32, mReserved: 0)
        var newFormat: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &interleavedASBD, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &newFormat)
        guard formatStatus == noErr, let newFormat else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var newSampleBuffer: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: newBlockBuffer, formatDescription: newFormat,
            sampleCount: frameCount, presentationTimeStamp: pts,
            packetDescriptions: nil, sampleBufferOut: &newSampleBuffer)
        guard createStatus == noErr else { return nil }
        return newSampleBuffer
    }
}

public enum RecordingError: Error {
    case sourceUnavailable
    case permissionDenied
}
