import AVFoundation

public enum AudioProcessorError: Error { case unreadable(URL), conversionFailed }

public enum AudioProcessor {
    static let workFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                          channels: 1, interleaved: false)!

    /// Reads any PCM audio file, RNNoise-denoises, writes 48 kHz mono Float32 CAF.
    public static func denoise(input: URL, output: URL) throws {
        let samples = try readMono48k(input)
        let denoiser = RNNoiseDenoiser()
        var out = [Float]()
        out.reserveCapacity(samples.count)
        var frame = [Float](repeating: 0, count: RNNoiseDenoiser.frameSize)
        var i = 0
        while i < samples.count {
            let n = min(RNNoiseDenoiser.frameSize, samples.count - i)
            for j in 0..<n { frame[j] = samples[i + j] }
            if n < RNNoiseDenoiser.frameSize {
                for j in n..<RNNoiseDenoiser.frameSize { frame[j] = 0 }
            }
            denoiser.process(&frame)
            out.append(contentsOf: frame[0..<n])
            i += n
        }
        try writeMono48k(out, to: output)
    }

    // MARK: shared PCM I/O (Task 7 reuses these)

    static func readMono48k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat,
                                     frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        if inFormat.sampleRate == 48_000, inFormat.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: inBuf.floatChannelData![0],
                                             count: Int(inBuf.frameLength)))
        }
        let converter = AVAudioConverter(from: inFormat, to: workFormat)!
        var fed = false
        var result: [Float] = []
        // Sample-rate conversion may need several passes; loop until the converter drains.
        while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: 65_536)!
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .endOfStream; return nil }
                fed = true; outStatus.pointee = .haveData; return inBuf
            }
            if let error { throw error }
            result.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0],
                                                          count: Int(outBuf.frameLength)))
            if status == .endOfStream || status == .error || outBuf.frameLength == 0 { break }
        }
        return result
    }

    static func writeMono48k(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: workFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: workFormat,
                                   frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
    }
}
