import Foundation

public enum AudioCache {
    /// Deterministic processed variant of `input` inside `cacheDir`; generated on first request.
    public static func processedURL(for input: URL, cacheDir: URL,
                                    denoise: Bool, enhance: Bool) throws -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        let name = "\(stem).d\(denoise ? 1 : 0)e\(enhance ? 1 : 0).caf"
        let url = cacheDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try AudioProcessor.process(input: input, output: url, denoise: denoise, enhance: enhance)
        }
        return url
    }
}
