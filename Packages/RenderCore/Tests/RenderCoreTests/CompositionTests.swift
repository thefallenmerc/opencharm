import AVFoundation
import CoreImage
import XCTest
@testable import RenderCore

final class CompositionTests: XCTestCase {
    /// Read every output frame of the built composition through the REAL pipeline.
    func renderedFrames(_ built: BuiltComposition) throws -> [CVPixelBuffer] {
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = built.videoComposition
        reader.add(output)
        reader.startReading()
        var frames: [CVPixelBuffer] = []
        while let sb = output.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(pb) }
        }
        XCTAssertNotEqual(reader.status, .failed, "\(String(describing: reader.error))")
        return frames
    }

    func testScreenOnlyCompositionRendersStyledFrames() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1))
        var settings = RenderSettings.default
        settings.background = .solid(RGBAColor(r: 1, g: 0, b: 0))
        settings.webcam.visible = false
        settings.shadow.opacity = 0

        let built = try await ProjectCompositionBuilder.build(
            timeline: MediaTimeline(
                screen: .init(url: screenURL, startOffset: 0), webcam: nil, audio: []),
            settings: settings, canvasSize: CGSize(width: 320, height: 240),
            backgroundImage: nil)

        let frames = try renderedFrames(built)
        XCTAssertGreaterThan(frames.count, 15) // ~2 s at 10 fps source → ≥ that many output frames
        let frame = frames[frames.count / 2]
        XCTAssertEqual(CVPixelBufferGetWidth(frame), 320)
        // Corner = background (red); center = screen content (blue).
        let corner = MovieFixture.averageColor(of: frame, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertGreaterThan(corner.r, 0.8); XCTAssertLessThan(corner.b, 0.2)
        let center = MovieFixture.averageColor(of: frame, in: CGRect(x: 158, y: 118, width: 4, height: 4))
        XCTAssertGreaterThan(center.b, 0.8); XCTAssertLessThan(center.r, 0.2)
    }

    func testWebcamOffsetAppearsMidway() async throws {
        let screenURL = try await MovieFixture.make(color: CIColor(red: 0, green: 0, blue: 1))
        let camURL = try await MovieFixture.make(color: CIColor(red: 0, green: 1, blue: 0),
                                                 seconds: 1)
        var settings = RenderSettings.default
        settings.background = .solid(RGBAColor(r: 1, g: 0, b: 0))
        settings.shadow.opacity = 0
        settings.webcam = WebcamSettings(visible: true, center: CGPoint(x: 0.85, y: 0.85),
                                         size: 0.3, roundness: 0)

        let built = try await ProjectCompositionBuilder.build(
            timeline: MediaTimeline(
                screen: .init(url: screenURL, startOffset: 0),
                webcam: .init(url: camURL, startOffset: 1.0), // webcam starts 1 s in
                audio: []),
            settings: settings, canvasSize: CGSize(width: 320, height: 240),
            backgroundImage: nil)

        let frames = try renderedFrames(built)
        // Webcam bubble center ≈ (272, 204) top-left coords; size 0.3*240=72.
        let bubbleProbe = CGRect(x: 270, y: 202, width: 4, height: 4)
        let early = MovieFixture.averageColor(of: frames[2], in: bubbleProbe)   // t ≈ 0.2 s: no webcam yet
        XCTAssertLessThan(early.g, 0.5, "bubble should not be green before webcam start")
        let late = MovieFixture.averageColor(of: frames[frames.count - 3], in: bubbleProbe) // t ≈ 1.7 s
        XCTAssertGreaterThan(late.g, 0.8, "bubble should show green webcam after its offset")
    }
}
