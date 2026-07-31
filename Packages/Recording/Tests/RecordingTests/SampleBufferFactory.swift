import AVFoundation
import CoreMedia

enum SampleBufferFactory {
    static func videoBuffer(pts: CMTime, size: CGSize = CGSize(width: 64, height: 64)) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pixelBuffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer!,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer!,
                                                 formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return sb!
    }

    static func audioBuffer(pts: CMTime, frames: Int = 4800, sampleRate: Double = 48_000) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0,
                                       layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        let byteCount = frames * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
                                           blockLength: byteCount, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0,
                                           dataLength: byteCount, flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0,
                                   dataLength: byteCount)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!,
            sampleCount: frames, presentationTimeStamp: pts,
            packetDescriptions: nil, sampleBufferOut: &sb)
        return sb!
    }

    /// Non-interleaved (planar), 16-bit signed-integer PCM — a format `ScreenRecorder.interleaved`
    /// must NOT attempt to reinterpret as `Float32`. Mirrors the real ScreenCaptureKit delivery
    /// shape (per-channel planar data in one contiguous block) but with an integer sample format,
    /// to exercise the pass-through guard.
    static func nonInterleavedInt16Buffer(pts: CMTime, frames: Int = 4800, sampleRate: Double = 48_000,
                                          channels: UInt32 = 2) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0,
                                       layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        let bytesPerChannel = frames * 2
        let byteCount = bytesPerChannel * Int(channels)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
                                           blockLength: byteCount, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0,
                                           dataLength: byteCount, flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0,
                                   dataLength: byteCount)
        var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                  sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                  sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        return sb!
    }
}
