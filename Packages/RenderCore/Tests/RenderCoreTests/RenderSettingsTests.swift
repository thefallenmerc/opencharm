import XCTest
@testable import RenderCore

final class RenderSettingsTests: XCTestCase {
    func testDefaultsAreSane() {
        let s = RenderSettings.default
        XCTAssertEqual(s.paddingFraction, 0.06, accuracy: 0.0001)
        XCTAssertEqual(s.cornerRadiusFraction, 0.02, accuracy: 0.0001)
        XCTAssertTrue(s.webcam.visible)
        XCTAssertEqual(s.webcam.center, CGPoint(x: 0.87, y: 0.82)) // bottom-right, y measured from TOP
        XCTAssertEqual(s.webcam.size, 0.24, accuracy: 0.0001)
        XCTAssertEqual(s.webcam.roundness, 1.0, accuracy: 0.0001) // circle
    }

    func testCodableRoundTrip() throws {
        var s = RenderSettings.default
        s.background = .linearGradient(
            start: RGBAColor(r: 0.1, g: 0.2, b: 0.9, a: 1),
            end: RGBAColor(r: 0.9, g: 0.3, b: 0.5, a: 1),
            angleDegrees: 45)
        s.webcam.roundness = 0.3
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(RenderSettings.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testImageBackgroundRoundTrip() throws {
        let s = Background.image(path: "preset:aurora")
        let back = try JSONDecoder().decode(Background.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(s, back)
    }
}
