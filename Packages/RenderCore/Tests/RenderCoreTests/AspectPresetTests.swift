import XCTest
@testable import RenderCore

final class AspectPresetTests: XCTestCase {
    let source = CGSize(width: 3000, height: 2000) // 3:2

    func testAutoReturnsSource() {
        XCTAssertEqual(AspectPreset.auto.canvasSize(for: source), source)
    }

    func testWiderPresetExtendsWidth() {
        // 16:9 is wider than 3:2 → keep height, widen. 2000 * 16/9 = 3555.55 → 3554 (even).
        let s = AspectPreset.wide16x9.canvasSize(for: source)
        XCTAssertEqual(s.height, 2000)
        XCTAssertEqual(s.width, 3554)
        XCTAssertEqual(Int(s.width) % 2, 0)
    }

    func testNarrowerPresetExtendsHeight() {
        // 1:1 is narrower than 3:2 → keep width, heighten. 3000x3000.
        XCTAssertEqual(AspectPreset.square.canvasSize(for: source), CGSize(width: 3000, height: 3000))
    }

    func testVerticalPreset() {
        // 9:16 → keep width, height = 3000 * 16/9 = 5333.33 → 5332 (even).
        XCTAssertEqual(AspectPreset.vertical9x16.canvasSize(for: source),
                       CGSize(width: 3000, height: 5332))
    }

    func testRenderSettingsDecodesWithoutAspect() throws {
        // Additive: settings persisted before the field existed decode to nil.
        let data = try JSONEncoder().encode(RenderSettings.default)
        let decoded = try JSONDecoder().decode(RenderSettings.self, from: data)
        XCTAssertNil(decoded.aspect)
    }
}
