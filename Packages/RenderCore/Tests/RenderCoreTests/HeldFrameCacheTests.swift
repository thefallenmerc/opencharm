import AVFoundation
import CoreImage
import XCTest
@testable import RenderCore

final class HeldFrameCacheTests: XCTestCase {
    private func time(_ seconds: Int) -> CMTime { CMTime(value: CMTimeValue(seconds), timescale: 1) }
    private func image(_ tag: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: tag, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testNoFrameEverHeldReturnsNil() {
        var cache = HeldFrameCache()
        XCTAssertNil(cache.resolve(source: nil, at: time(0)))
    }

    func testRealFrameIsReturnedAndPrimesTheCache() {
        var cache = HeldFrameCache()
        let frame = image(1)
        let result = cache.resolve(source: frame, at: time(1))
        XCTAssertTrue(result === frame)
    }

    func testForwardGapReturnsHeldFrame() {
        var cache = HeldFrameCache()
        let frame = image(1)
        _ = cache.resolve(source: frame, at: time(1))
        // SCK delivered nothing for several frames after — time keeps moving forward.
        XCTAssertTrue(cache.resolve(source: nil, at: time(2)) === frame)
        XCTAssertTrue(cache.resolve(source: nil, at: time(5)) === frame)
    }

    func testEqualTimeCountsAsForwardAndReturnsHeldFrame() {
        var cache = HeldFrameCache()
        let frame = image(1)
        _ = cache.resolve(source: frame, at: time(3))
        XCTAssertTrue(cache.resolve(source: nil, at: time(3)) === frame)
    }

    func testBackwardTimeInvalidatesAndReturnsNil() {
        var cache = HeldFrameCache()
        let frame = image(1)
        _ = cache.resolve(source: frame, at: time(5))
        // Preview scrubbed backwards past the last real frame's time.
        let result = cache.resolve(source: nil, at: time(2))
        XCTAssertNil(result, "backward seek must not reuse a frame from later in the timeline")
    }

    func testInvalidationPersistsUntilANewRealFrameArrives() {
        var cache = HeldFrameCache()
        let frame = image(1)
        _ = cache.resolve(source: frame, at: time(5))
        XCTAssertNil(cache.resolve(source: nil, at: time(2))) // invalidate
        // Still no real frame yet — must keep returning nil, not resurrect the stale frame.
        XCTAssertNil(cache.resolve(source: nil, at: time(3)))
    }

    func testNewFrameAfterInvalidationRePrimes() {
        var cache = HeldFrameCache()
        let first = image(1)
        let second = image(2)
        _ = cache.resolve(source: first, at: time(5))
        _ = cache.resolve(source: nil, at: time(2)) // backward seek: invalidate
        let result = cache.resolve(source: second, at: time(2))
        XCTAssertTrue(result === second)
        // And it holds forward from the new frame's time.
        XCTAssertTrue(cache.resolve(source: nil, at: time(3)) === second)
    }
}
