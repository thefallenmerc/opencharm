import AVFoundation

enum AudioFixture {
    /// Writes a `seconds`-long mono 44.1 kHz PCM `.caf` tone — a real, readable audio asset for
    /// builder tests (mirrors how mic/system audio is stored: `ProjectPackage.micURL` is also
    /// `.caf`).
    static func make(seconds: Double, frequency: Double = 440) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-fix-\(UUID().uuidString).caf")
        let sampleRate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            channel[i] = Float(sin(2 * .pi * frequency * Double(i) / sampleRate)) * 0.2
        }
        try file.write(from: buffer)
        return url
    }
}
