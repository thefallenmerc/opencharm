import AVFoundation
import AudioToolbox

public enum AudioProcessorError: Error {
    case unreadable(URL)
    case conversionFailed
    /// Offline manual rendering returned a non-`.success` status.
    case renderFailed(AVAudioEngineManualRenderingStatus)
}

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

    /// High-pass at 80 Hz, gentle presence lift, dynamics compression. Offline render.
    ///
    /// Renders to a temp file beside `output` and only moves it into place once
    /// rendering fully succeeds — a mid-render failure (engine start, a
    /// non-`.success` render status, a write error) never leaves a partial/corrupt
    /// file sitting at `output`, which `AudioCache` would otherwise treat as a
    /// permanent (and broken) cache hit via its `fileExists` check.
    public static func enhance(input: URL, output: URL) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 80
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 3000
        eq.bands[1].bandwidth = 1.0
        eq.bands[1].gain = 2.5
        eq.bands[1].bypass = false
        let comp = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))

        let file = try AVAudioFile(forReading: input)
        engine.attach(player); engine.attach(eq); engine.attach(comp)
        pinDynamicsProcessorDefaults(comp)
        engine.connect(player, to: eq, format: file.processingFormat)
        engine.connect(eq, to: comp, format: file.processingFormat)
        engine.connect(comp, to: engine.mainMixerNode, format: file.processingFormat)
        // Registered before any throwing call below so a failure at any point
        // (enable-rendering-mode, start, mid-render) still stops the engine —
        // both calls are safe no-ops if the engine never actually started.
        defer { player.stop(); engine.stop() }

        try engine.enableManualRenderingMode(.offline, format: workFormat,
                                             maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(file, at: nil)
        player.play()

        let tmp = output.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outFile = try AVAudioFile(forWriting: tmp, settings: workFormat.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        let renderBuf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                         frameCapacity: 4096)!
        let total = AVAudioFramePosition(
            Double(file.length) * 48_000 / file.processingFormat.sampleRate)
        while engine.manualRenderingSampleTime < total {
            let toRender = AVAudioFrameCount(min(4096, total - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(toRender, to: renderBuf)
            guard status == .success else {
                throw AudioProcessorError.renderFailed(status)
            }
            try outFile.write(from: renderBuf)
        }
        // Full render succeeded: atomically publish. `moveItem` is a rename on
        // the same volume (both paths share `output`'s directory), so `output`
        // is never observable in a partial state by a concurrent reader (e.g.
        // another `AudioCache.processedURL` caller's `fileExists` check).
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: tmp, to: output)
    }

    /// Pins Apple's `AUDynamicsProcessor` to its documented factory-default
    /// parameter values (see `AudioUnitParameters.h`: Threshold -20 dB, HeadRoom
    /// 5 dB, ExpansionRatio 2, AttackTime 0.001 s, ReleaseTime 0.05 s, OverallGain
    /// 0 dB) so `enhance`'s output is deterministic across macOS versions instead
    /// of riding on whatever the AU happens to initialize its parameters to.
    private static func pinDynamicsProcessorDefaults(_ comp: AVAudioUnitEffect) {
        let au = comp.audioUnit
        let defaults: [(AudioUnitParameterID, AudioUnitParameterValue)] = [
            (kDynamicsProcessorParam_Threshold, -20),    // dB,   range -40...20
            (kDynamicsProcessorParam_HeadRoom, 5),        // dB,   range 0.1...40
            (kDynamicsProcessorParam_ExpansionRatio, 2),  // rate, range 1...50
            (kDynamicsProcessorParam_AttackTime, 0.001),  // secs, range 0.0001...0.2
            (kDynamicsProcessorParam_ReleaseTime, 0.05),  // secs, range 0.01...3
            (kDynamicsProcessorParam_OverallGain, 0),     // dB,   range -40...40
        ]
        for (id, value) in defaults {
            AudioUnitSetParameter(au, id, kAudioUnitScope_Global, 0, value, 0)
        }
    }

    /// Full chain used by the app. Both flags false → normalize to 48k mono only.
    public static func process(input: URL, output: URL, denoise: Bool, enhance: Bool) throws {
        let tmp = output.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        switch (denoise, enhance) {
        case (false, false):
            try writeMono48k(try readMono48k(input), to: output)
        case (true, false):
            try Self.denoise(input: input, output: output)
        case (false, true):
            try Self.enhance(input: input, output: output)
        case (true, true):
            try Self.denoise(input: input, output: tmp)
            try Self.enhance(input: tmp, output: output)
        }
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

    /// Writes to a temp file beside `url` and atomically moves it into place only
    /// once the write fully succeeds, so a mid-write failure never leaves a
    /// partial file at `url`. This is the shared final-write step for `denoise`
    /// and `process`'s passthrough branch, so both inherit the same atomicity
    /// guarantee as `enhance`.
    static func writeMono48k(_ samples: [Float], to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try AVAudioFile(forWriting: tmp, settings: workFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: workFormat,
                                   frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
