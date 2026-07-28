import AppKit
import CoreImage
import XCTest

enum GoldenAssert {
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static func cgImage(_ image: CIImage) -> CGImage {
        context.createCGImage(image, from: image.extent,
                              format: .RGBA8,
                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    static func pngData(_ cg: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])!
    }

    /// Mean absolute per-channel difference in 0–1 space.
    static func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {
        func bytes(_ img: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let ctx = CGContext(data: &data, width: img.width, height: img.height,
                                bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return data
        }
        let (pa, pb) = (bytes(a), bytes(b))
        guard pa.count == pb.count else { return 1 }
        var total = 0.0
        for i in 0..<pa.count { total += abs(Double(pa[i]) - Double(pb[i])) }
        return total / Double(pa.count) / 255.0
    }

    static func compare(_ image: CIImage, name: String,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let cg = cgImage(image)
        let sourceGoldens = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().appendingPathComponent("Goldens")
        let goldenFile = sourceGoldens.appendingPathComponent("\(name).png")

        if ProcessInfo.processInfo.environment["RECORD_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: sourceGoldens, withIntermediateDirectories: true)
            try pngData(cg).write(to: goldenFile)
            throw XCTSkip("Recorded golden \(name).png — re-run without RECORD_GOLDENS")
        }
        guard let url = Bundle.module.url(forResource: "Goldens/\(name)", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let golden = CGImage(pngDataProviderSource: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent) else {
            XCTFail("Missing golden \(name).png — run once with RECORD_GOLDENS=1", file: file, line: line)
            return
        }
        let diff = meanAbsDiff(cg, golden)
        XCTAssertLessThan(diff, 0.01, "Golden mismatch for \(name) (meanAbsDiff \(diff))",
                          file: file, line: line)
    }
}
