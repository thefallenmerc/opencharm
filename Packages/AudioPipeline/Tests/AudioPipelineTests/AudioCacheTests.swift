import XCTest
@testable import AudioPipeline

final class AudioCacheTests: XCTestCase {
    func testGeneratesOnceAndNames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-\(UUID().uuidString)")
        var samples = [Float](repeating: 0, count: 48_000)
        for i in samples.indices { samples[i] = Float(sin(Double(i) * 0.05)) * 0.2 }
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-\(UUID().uuidString).caf")
        try AudioProcessor.writeMono48k(samples, to: src)

        let url1 = try AudioCache.processedURL(for: src, cacheDir: dir, denoise: true, enhance: false)
        XCTAssertEqual(url1.lastPathComponent, "\(src.deletingPathExtension().lastPathComponent).d1e0.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url1.path))
        let mtime1 = try FileManager.default.attributesOfItem(atPath: url1.path)[.modificationDate] as! Date
        let url2 = try AudioCache.processedURL(for: src, cacheDir: dir, denoise: true, enhance: false)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: url2.path)[.modificationDate] as! Date
        XCTAssertEqual(mtime1, mtime2, "second call must hit the cache")
    }
}
