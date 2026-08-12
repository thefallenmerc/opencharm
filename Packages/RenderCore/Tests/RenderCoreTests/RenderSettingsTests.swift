import XCTest
@testable import RenderCore

final class RenderSettingsTests: XCTestCase {
    func testDefaultsAreSane() {
        let s = RenderSettings.default
        XCTAssertEqual(s.paddingFraction, 0.06, accuracy: 0.0001)
        XCTAssertEqual(s.cornerRadiusFraction, 0.02, accuracy: 0.0001)
        XCTAssertTrue(s.webcam.visible)
        XCTAssertEqual(s.webcam.center, CGPoint(x: 0.87, y: 0.82)) // bottom-right, y measured from TOP
        XCTAssertEqual(s.webcam.size, 0.58, accuracy: 0.0001)     // 1.2× the original default
        XCTAssertEqual(s.webcam.roundness, 0.65, accuracy: 0.0001) // squircle, not a circle
        XCTAssertEqual(s.autoZoom?.enabled, true) // zoom-on-click on by default
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

    func testZoomSpecMapsToSegment() {
        let spec = ZoomSpec(id: "a", start: 1, end: 3, easeIn: 0.4, easeOut: 0.5,
                            focus: CGPoint(x: 0.3, y: 0.6), scale: 2.5, manual: true)
        let seg = spec.segment
        XCTAssertEqual(seg.start, 1); XCTAssertEqual(seg.end, 3)
        XCTAssertEqual(seg.easeIn, 0.4); XCTAssertEqual(seg.easeOut, 0.5)
        XCTAssertEqual(seg.focus, CGPoint(x: 0.3, y: 0.6)); XCTAssertEqual(seg.scale, 2.5)
    }

    func testZoomsAndTrimRoundTrip() throws {
        var s = RenderSettings.default
        s.zooms = [ZoomSpec(id: "z1", start: 0.5, end: 2.0, easeIn: 0.4, easeOut: 0.5,
                            focus: CGPoint(x: 0.4, y: 0.4), scale: 2, manual: false)]
        s.trimStart = 0.25; s.trimEnd = 8.75
        let back = try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(s, back)
    }

    // A settings blob written before zooms/trim existed must still decode, with those fields nil.
    func testDecodesLegacySettingsWithoutZoomsOrTrim() throws {
        let legacy = #"""
        {"background":{"solid":{"_0":{"r":0.1,"g":0.1,"b":0.1,"a":1}}},
         "paddingFraction":0.06,"cornerRadiusFraction":0.02,
         "shadow":{"opacity":0.4,"radius":0.03,"offsetY":0.01},
         "webcam":{"visible":true,"center":[0.87,0.82],"size":0.24,"roundness":1}}
        """#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RenderSettings.self, from: legacy)
        XCTAssertNil(s.zooms); XCTAssertNil(s.trimStart); XCTAssertNil(s.trimEnd)
        XCTAssertNil(s.autoZoom)
    }
}
