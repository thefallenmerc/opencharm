import CRNNoise

/// Streams 48 kHz mono float frames (±1.0) through RNNoise. Not thread-safe; one per stream.
final class RNNoiseDenoiser {
    static let frameSize = 480 // 10 ms at 48 kHz, fixed by RNNoise
    private let state: OpaquePointer

    init() { state = rnnoise_create(nil) }
    deinit { rnnoise_destroy(state) }

    /// In-place processes exactly `frameSize` samples.
    func process(_ frame: inout [Float]) {
        precondition(frame.count == Self.frameSize)
        for i in frame.indices { frame[i] *= 32768 } // RNNoise expects short-range floats
        frame.withUnsafeMutableBufferPointer { buf in
            _ = rnnoise_process_frame(state, buf.baseAddress, buf.baseAddress)
        }
        for i in frame.indices { frame[i] /= 32768 }
    }
}
