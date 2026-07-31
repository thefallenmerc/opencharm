import AVFoundation
import XCTest
@testable import Recording

final class DeviceRecorderTests: XCTestCase {
    func firstDevice(_ mediaType: AVMediaType) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] =
            mediaType == .video ? [.builtInWideAngleCamera, .external] : [.microphone]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: mediaType, position: .unspecified).devices.first
    }

    func testWebcamRecordsMovie() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil)
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = firstDevice(.video) else { throw XCTSkip("no authorized camera") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-\(UUID().uuidString).mov")
        let rec = try WebcamRecorder(deviceID: device.uniqueID, outputURL: url)
        try await rec.start()
        try await Task.sleep(for: .seconds(2))
        try await rec.stop()
        XCTAssertNotNil(rec.firstPTS)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertGreaterThan(duration, 1.0)
    }

    func testMicRecordsCAF() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = firstDevice(.audio) else { throw XCTSkip("no authorized mic") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-\(UUID().uuidString).caf")
        let rec = try MicRecorder(deviceID: device.uniqueID, outputURL: url)
        try rec.start()
        try await Task.sleep(for: .seconds(2))
        try await rec.stop()
        XCTAssertNotNil(rec.firstPTS)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(Double(file.length) / file.processingFormat.sampleRate, 1.0)
    }
}
