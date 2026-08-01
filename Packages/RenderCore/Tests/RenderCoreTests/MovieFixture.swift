import AVFoundation
import CoreImage

enum MovieFixture {
    /// Writes a `seconds`-long movie of a solid color at 10 fps.
    static func make(color: CIColor, size: CGSize = CGSize(width: 128, height: 96),
                     seconds: Double = 2) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fix-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let ctx = CIContext()
        let image = CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
        var pool: CVPixelBuffer?
        for i in 0..<Int(seconds * 10) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pool)
            ctx.render(image, to: pool!)
            adaptor.append(pool!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// Average color of the pixel-buffer region (BGRA).
    static func averageColor(of buffer: CVPixelBuffer, in region: CGRect) -> (r: Double, g: Double, b: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var (r, g, b, n) = (0.0, 0.0, 0.0, 0.0)
        let height = CVPixelBufferGetHeight(buffer)
        for y in Int(region.minY)..<Int(region.maxY) {
            // CVPixelBuffer row 0 is the TOP of the image; region is given top-left too.
            guard y >= 0, y < height else { continue }
            for x in Int(region.minX)..<Int(region.maxX) {
                let p = y * stride + x * 4
                b += Double(base[p]); g += Double(base[p + 1]); r += Double(base[p + 2])
                n += 1
            }
        }
        return (r / n / 255, g / n / 255, b / n / 255)
    }
}
