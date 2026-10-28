import XCTest
@testable import azooKey

final class TsukaimaSwipeIntentTests: XCTestCase {
    private func v(deg: Double, len: CGFloat = 100) -> TsukaimaSwipeIntent.Verdict {
        // 縦から deg 度
        let r = deg * .pi / 180
        return TsukaimaSwipeIntent.verdict(dx: len * CGFloat(sin(r)), dy: len * CGFloat(cos(r)))
    }

    func testVerticalWithinSixtyDegrees() {
        XCTAssertEqual(v(deg: 0), .vertical)
        XCTAssertEqual(v(deg: 30), .vertical)
        XCTAssertEqual(v(deg: 50), .vertical)
        XCTAssertEqual(v(deg: 58), .vertical)
    }

    func testClearlyHorizontalOnlyWhenWideAndFar() {
        XCTAssertEqual(v(deg: 90), .horizontal)
        XCTAssertEqual(v(deg: 75), .horizontal)
        // 横寄りでも 24pt に満たなければ決めない
        XCTAssertEqual(TsukaimaSwipeIntent.verdict(dx: 20, dy: 0), .undecided)
    }

    func testDiagonalBetweenIsNotHorizontal() {
        // 62〜63 度付近は縦でも横でもない(親の横スワイプは始まらない)
        XCTAssertEqual(v(deg: 62), .undecided)
        XCTAssertEqual(v(deg: 63), .undecided)
    }

    func testTinyMovementUndecided() {
        XCTAssertEqual(TsukaimaSwipeIntent.verdict(dx: 2, dy: 3), .undecided)
        XCTAssertEqual(TsukaimaSwipeIntent.verdict(dx: 0, dy: 0), .undecided)
    }
}
