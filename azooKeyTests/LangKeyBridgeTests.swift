import XCTest
@testable import azooKey

final class LangKeyBridgeTests: XCTestCase {
    private let down2 = "window.dispatchEvent(new KeyboardEvent('keydown', {code:'Lang2', key:'Lang2', bubbles:true}))"
    private let up2 = "window.dispatchEvent(new KeyboardEvent('keyup', {code:'Lang2', key:'Lang2', bubbles:true}))"
    private let down1 = "window.dispatchEvent(new KeyboardEvent('keydown', {code:'Lang1', key:'Lang1', bubbles:true}))"
    private let up1 = "window.dispatchEvent(new KeyboardEvent('keyup', {code:'Lang1', key:'Lang1', bubbles:true}))"
    private let downCapsLock = "window.dispatchEvent(new KeyboardEvent('keydown', {code:'CapsLock', key:'CapsLock', bubbles:true}))"
    private let upCapsLock = "window.dispatchEvent(new KeyboardEvent('keyup', {code:'CapsLock', key:'CapsLock', bubbles:true}))"

    /// 成功し続けたときに流れる JS を全部取り出す
    private func drain(_ q: inout LangKeyEventQueue) -> [String] {
        var out: [String] = []
        while let s = q.next() {
            out.append(s)
            q.complete(success: true)
        }
        return out
    }

    func testExactScripts() {
        XCTAssertEqual(LangKeyEventQueue.script(type: "keydown", key: .lang2), down2)
        XCTAssertEqual(LangKeyEventQueue.script(type: "keyup", key: .lang1), up1)
        XCTAssertEqual(LangKey.lang1.rawValue, 0x90)
        XCTAssertEqual(LangKey.lang2.rawValue, 0x91)
        XCTAssertEqual(LangKeyEventQueue.script(type: "keydown", key: .capsLock), downCapsLock)
        XCTAssertEqual(LangKey.capsLock.rawValue, 0x39)
    }

    func testDownThenUpInOrder() {
        var q = LangKeyEventQueue()
        XCTAssertTrue(q.press(usage: 0x91, phase: .down))
        XCTAssertTrue(q.press(usage: 0x91, phase: .up))
        XCTAssertEqual(drain(&q), [down2, up2])
    }

    func testOtherUsagesAreNotConsumed() {
        var q = LangKeyEventQueue()
        XCTAssertFalse(q.press(usage: 0x04, phase: .down)) // A
        XCTAssertFalse(q.press(usage: 0x2C, phase: .down)) // Space
        XCTAssertFalse(q.press(usage: 0x92, phase: .down)) // LANG3
        XCTAssertFalse(q.press(usage: 0x39, phase: .down)) // practice page 以外の Caps Lock
        XCTAssertTrue(q.pending.isEmpty)
        XCTAssertTrue(q.down.isEmpty)
    }

    func testAutoRepeatDownIsNotResent() {
        var q = LangKeyEventQueue()
        q.press(usage: 0x91, phase: .down)
        XCTAssertTrue(q.press(usage: 0x91, phase: .down)) // 消費はするが積まない
        q.press(usage: 0x91, phase: .up)
        XCTAssertEqual(drain(&q), [down2, up2])
    }

    func testCapsLockDownUpAndAutoRepeat() {
        var q = LangKeyEventQueue(acceptsCapsLock: true)
        XCTAssertTrue(q.press(usage: 0x39, phase: .down))
        XCTAssertTrue(q.press(usage: 0x39, phase: .down)) // long press/repeat must not add a second keydown
        XCTAssertTrue(q.press(usage: 0x39, phase: .up))
        XCTAssertEqual(drain(&q), [downCapsLock, upCapsLock])
    }

    func testCancelAllReleasesHeldCapsLock() {
        var q = LangKeyEventQueue(acceptsCapsLock: true)
        q.press(usage: 0x39, phase: .down)
        q.cancelAll()
        q.press(usage: 0x39, phase: .up) // delayed physical keyup must not duplicate it
        XCTAssertEqual(drain(&q), [downCapsLock, upCapsLock])
    }

    func testUpForKeyNotHeldIsIgnoredButConsumed() {
        var q = LangKeyEventQueue()
        XCTAssertTrue(q.press(usage: 0x90, phase: .up))
        XCTAssertTrue(q.pending.isEmpty)
    }

    func testInterleavedLang1AndLang2KeepOrder() {
        var q = LangKeyEventQueue()
        q.press(usage: 0x91, phase: .down)
        q.press(usage: 0x90, phase: .down)
        q.press(usage: 0x91, phase: .up)
        q.press(usage: 0x90, phase: .up)
        XCTAssertEqual(drain(&q), [down2, down1, up2, up1])
    }

    func testOnlyOneEvaluationInFlight() {
        var q = LangKeyEventQueue()
        q.press(usage: 0x91, phase: .down)
        q.press(usage: 0x91, phase: .up)
        XCTAssertEqual(q.next(), down2)
        XCTAssertNil(q.next()) // 評価中は次を出さない
        q.complete(success: true)
        XCTAssertEqual(q.next(), up2)
    }

    func testFailureKeepsHeadAndFlushesInOrderAfterPageReady() {
        var q = LangKeyEventQueue()
        q.press(usage: 0x91, phase: .down)
        XCTAssertEqual(q.next(), down2)
        q.complete(success: false)
        q.press(usage: 0x91, phase: .up)
        XCTAssertNil(q.next()) // ページが用意できるまで止まる
        q.pageReady()
        XCTAssertEqual(drain(&q), [down2, up2]) // 失敗した down が先頭のまま、up は落ちない
    }

    func testUpIsNeverDroppedAfterFailureOfUp() {
        var q = LangKeyEventQueue()
        q.press(usage: 0x91, phase: .down)
        q.press(usage: 0x91, phase: .up)
        XCTAssertEqual(q.next(), down2)
        q.complete(success: true)
        XCTAssertEqual(q.next(), up2)
        q.complete(success: false)
        XCTAssertNil(q.next())
        q.pageReady()
        XCTAssertEqual(drain(&q), [up2])
    }

    func testCancelAllEmitsUpForHeldKeysOnlyOnce() {
        var q = LangKeyEventQueue()
        q.press(usage: 0x91, phase: .down)
        q.press(usage: 0x90, phase: .down)
        q.press(usage: 0x90, phase: .up)
        q.cancelAll()
        q.cancelAll() // 2 回目は何も積まない
        XCTAssertTrue(q.down.isEmpty)
        XCTAssertEqual(drain(&q), [down2, down1, up1, up2])
    }

    func testCancelAllWithNothingHeldIsNoop() {
        var q = LangKeyEventQueue()
        q.cancelAll()
        XCTAssertTrue(q.pending.isEmpty)
    }

    func testUpAfterCancelAllIsIgnored() {
        var q = LangKeyEventQueue()
        q.press(usage: 0x91, phase: .down)
        q.cancelAll()
        q.press(usage: 0x91, phase: .up) // 遅れて来た本物の up は二重にしない
        XCTAssertEqual(drain(&q), [down2, up2])
    }
}
