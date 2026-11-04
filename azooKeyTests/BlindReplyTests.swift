import Foundation
import XCTest
@testable import azooKey

final class BlindReplyTests: XCTestCase {
    // MARK: 持ち主の規則

    func testPlaybackOnlyStartsOnlyWhenStoppedAndOwnsIt() {
        var o = PlaybackOwnership()
        XCTAssertFalse(o.isRunning)
        XCTAssertTrue(o.beginPlaybackOnly())
        XCTAssertTrue(o.isPlaybackOnly)
        // 2 つ目の画面は持ち主になれない
        XCTAssertFalse(o.beginPlaybackOnly())
    }

    func testPlaybackOnlyIsNotOwnedWhenConversationAlreadyRuns() {
        var o = PlaybackOwnership()
        o.markFull()
        XCTAssertFalse(o.beginPlaybackOnly())
        XCTAssertEqual(o.mode, .full)
        // 持ち主でないので閉じても止めない
        XCTAssertFalse(o.stopIfOwned(false))
        XCTAssertEqual(o.mode, .full)
    }

    func testStopIfOwnedStopsOnlyOwnedPlaybackOnly() {
        var o = PlaybackOwnership()
        XCTAssertTrue(o.beginPlaybackOnly())
        XCTAssertFalse(o.stopIfOwned(false))
        XCTAssertTrue(o.isPlaybackOnly)
        XCTAssertTrue(o.stopIfOwned(true))
        XCTAssertFalse(o.isRunning)
        // 止まったあとは何も起きない
        XCTAssertFalse(o.stopIfOwned(true))
    }

    func testUpgradeToFullMakesBlindCloseHarmless() {
        var o = PlaybackOwnership()
        XCTAssertTrue(o.beginPlaybackOnly())
        o.markFull()  // 会話モードが始まって格上げ
        XCTAssertFalse(o.isPlaybackOnly)
        XCTAssertFalse(o.stopIfOwned(true))
        XCTAssertEqual(o.mode, .full)
        XCTAssertTrue(o.stop())
        XCTAssertFalse(o.isRunning)
        XCTAssertFalse(o.stop())
    }

    // MARK: listener メッセージ

    func testParseListener() {
        XCTAssertEqual(BlindLink.parseListener(#"{"type":"listener","on":true}"#), true)
        XCTAssertEqual(BlindLink.parseListener(#"{"type":"listener","on":false}"#), false)
    }

    func testParseListenerIgnoresOtherOrBrokenMessages() {
        XCTAssertNil(BlindLink.parseListener(#"{"type":"listener"}"#))
        XCTAssertNil(BlindLink.parseListener(#"{"type":"listener","on":"yes"}"#))
        XCTAssertNil(BlindLink.parseListener(#"{"type":"state","on":true}"#))
        XCTAssertNil(BlindLink.parseListener("not json"))
    }
}
