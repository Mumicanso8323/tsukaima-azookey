import XCTest
@testable import azooKey

final class FocusGuardPolicyTests: XCTestCase {
    private func decide(_ edit: (inout FocusGuardInputs) -> Void = { _ in }) -> FocusGuardDecision {
        var i = FocusGuardInputs()
        edit(&i)
        return FocusGuardPolicy.decide(i)
    }

    func testRestoresWhenEverythingIsClear() {
        XCTAssertEqual(decide(), .restore)
    }

    func testReleasedImmediatelyWhenHardwareKeyboardDisconnects() {
        XCTAssertEqual(decide { $0.hardwareAttached = false }, .abandon)
    }

    func testDoesNotFightUserMovingToAnotherField() {
        XCTAssertEqual(decide { $0.otherIsFirstResponder = true }, .abandon)
    }

    func testAnotherVisibleFieldOnlyWaitsAtFirstThenGivesUp() {
        // 画面遷移の途中で一瞬、別の欄が見えただけなら、見えなくなるのを待つ(固着しない)
        XCTAssertEqual(decide { $0.otherInputVisible = true }, .wait)
        // 長く見えたままなら、欄が複数ある画面とみなして戻すのをやめる(意思は残すので、時間では再判定しない)
        XCTAssertEqual(decide { $0.otherInputVisible = true; $0.waitedTooLong = true }, .idle)
        // 見えなくなれば戻す
        XCTAssertEqual(decide { $0.otherInputVisible = false; $0.waitedTooLong = true }, .restore)
    }

    func testKeyboardDismissalByUserIsNotUndone() {
        // ソフトウェアキーボードが出ている間に、アクティブな状態で、システム要因でなく外れたものは本人の操作
        XCTAssertTrue(FocusGuardPolicy.isUserDismissal(softKeyboardVisible: true, sceneActive: true, systemLoss: false))
        // 物理キーボードだけ(ソフトウェアキーボードが出ていない)なら、外れたものは戻す
        XCTAssertFalse(FocusGuardPolicy.isUserDismissal(softKeyboardVisible: false, sceneActive: true, systemLoss: false))
        // 背面に回る途中など、アクティブでない外れは本人の操作ではない
        XCTAssertFalse(FocusGuardPolicy.isUserDismissal(softKeyboardVisible: true, sceneActive: false, systemLoss: false))
        // システムが奪ったことが分かっているもの
        XCTAssertFalse(FocusGuardPolicy.isUserDismissal(softKeyboardVisible: true, sceneActive: true, systemLoss: true))
    }

    func testDoesNotRestoreWhatTheAppResignedOnPurpose() {
        XCTAssertEqual(decide { $0.wantsFocus = false }, .abandon)
    }

    func testWaitsWhileModalOrInactiveOrSettling() {
        XCTAssertEqual(decide { $0.modalPresented = true }, .wait)
        XCTAssertEqual(decide { $0.sceneActive = false }, .wait)
        XCTAssertEqual(decide { $0.windowIsKey = false }, .wait)
        XCTAssertEqual(decide { $0.settling = true }, .wait)
    }

    func testWaitsForWindowWhenTheScreenIsLeft() {
        XCTAssertEqual(decide { $0.inWindow = false }, .waitForWindow)
    }

    func testBreakerStopsRestoring() {
        XCTAssertEqual(decide { $0.tripped = true }, .abandon)
    }

    func testModalTakesPriorityOverWaitingForWindowOnlyWhenInWindow() {
        // 画面を離れている間はシートの有無に関わらず画面に戻るのを待つ
        XCTAssertEqual(decide { $0.inWindow = false; $0.modalPresented = true }, .waitForWindow)
    }

    func testRetryDelaysKeepWatchingWhileWaitingOrIdle() {
        // idle で時間の再判定が無いと、他の欄が消えても固定が戻らない
        XCTAssertEqual(FocusGuardPolicy.retryDelay(for: .wait), 0.5)
        XCTAssertEqual(FocusGuardPolicy.retryDelay(for: .idle), 2.0)
        XCTAssertNil(FocusGuardPolicy.retryDelay(for: .restore))
        XCTAssertNil(FocusGuardPolicy.retryDelay(for: .waitForWindow))
        XCTAssertNil(FocusGuardPolicy.retryDelay(for: .abandon))
    }

    func testIdleThenRestoresOnceTheOtherFieldGoesAway() {
        XCTAssertEqual(decide { $0.otherInputVisible = true; $0.waitedTooLong = true }, .idle)
        XCTAssertEqual(decide { $0.otherInputVisible = false; $0.waitedTooLong = true }, .restore)
    }

    func testSheetOpenWinsOverOtherFieldTimeout() {
        // シートが出ている間は(シートの中の欄が見えていても)待つだけ。あきらめない
        XCTAssertEqual(decide { $0.modalPresented = true; $0.otherInputVisible = true; $0.waitedTooLong = true }, .wait)
    }

    func testOtherFieldVisibilityIsNotCountedWhileSheetOpenOrInactive() {
        var v = OtherFieldVisibility()
        XCTAssertFalse(v.update(otherVisible: true, counting: false, now: 0, limit: 10))
        // シートが 30 秒出ていて、閉じる途中で欄が見えても、そこから数え始める
        XCTAssertFalse(v.update(otherVisible: true, counting: true, now: 30, limit: 10))
        XCTAssertFalse(v.update(otherVisible: true, counting: true, now: 39, limit: 10))
        XCTAssertTrue(v.update(otherVisible: true, counting: true, now: 41, limit: 10))
    }

    func testOtherFieldVisibilityResetsWhenItDisappears() {
        var v = OtherFieldVisibility()
        XCTAssertFalse(v.update(otherVisible: true, counting: true, now: 0, limit: 10))
        XCTAssertTrue(v.update(otherVisible: true, counting: true, now: 11, limit: 10))
        XCTAssertFalse(v.update(otherVisible: false, counting: true, now: 12, limit: 10))
        XCTAssertFalse(v.update(otherVisible: true, counting: true, now: 13, limit: 10))
    }

    func testSoftKeyboardTrackerIgnoresOtherAppsKeyboards() {
        var t = SoftKeyboardTracker()
        t.willChangeFrame(isLocal: false, visibleHeight: 300)
        XCTAssertFalse(t.visible, "他のアプリ(Split View など)のキーボードで旗を立てない")
        t.willChangeFrame(isLocal: true, visibleHeight: 300)
        XCTAssertTrue(t.visible)
        t.willHide(isLocal: false)
        XCTAssertTrue(t.visible, "他のアプリのキーボードが閉じても旗を下げない")
        t.willHide(isLocal: true)
        XCTAssertFalse(t.visible)
    }

    func testSoftKeyboardTrackerIgnoresShortcutBarAndResets() {
        var t = SoftKeyboardTracker()
        t.willChangeFrame(isLocal: true, visibleHeight: 55)
        XCTAssertFalse(t.visible, "物理キーボードの付属バーはソフトウェアキーボードではない")
        t.willChangeFrame(isLocal: true, visibleHeight: 291)
        XCTAssertTrue(t.visible)
        t.reset()
        XCTAssertFalse(t.visible)
    }

    // MARK: 2026-10-15 閉じたキーボードが開き直る(物理キーボードが無いのに GCKeyboard が残る)

    func testHardwareInUseOnlyWhileNoSoftKeyboardSinceConnect() {
        XCTAssertTrue(FocusGuardPolicy.hardwareInUse(gcKeyboard: true, softKeyboardSeenSinceConnect: false))
        XCTAssertFalse(FocusGuardPolicy.hardwareInUse(gcKeyboard: true, softKeyboardSeenSinceConnect: true),
                       "画面のキーボードが出たなら、物理キーボードで打っていない")
        XCTAssertFalse(FocusGuardPolicy.hardwareInUse(gcKeyboard: false, softKeyboardSeenSinceConnect: false))
    }

    func testSoftKeyboardSeenIsClearedOnlyByReconnect() {
        var t = SoftKeyboardTracker()
        XCTAssertFalse(t.seenSinceConnect)
        t.willChangeFrame(isLocal: true, visibleHeight: 55, now: 1)
        XCTAssertFalse(t.seenSinceConnect, "付属バーだけでは、画面のキーボードとみなさない")
        t.willChangeFrame(isLocal: true, visibleHeight: 300, now: 2)
        XCTAssertTrue(t.seenSinceConnect)
        t.willHide(isLocal: true, now: 3)
        t.reset()
        XCTAssertTrue(t.seenSinceConnect, "隠れても・背面に回っても、接続し直すまでは残す")
        t.hardwareConnected()
        XCTAssertFalse(t.seenSinceConnect)
    }

    func testJustHiddenCountsAsVisibleForDismissal() {
        var t = SoftKeyboardTracker()
        t.willChangeFrame(isLocal: true, visibleHeight: 300, now: 10)
        t.willHide(isLocal: true, now: 11)
        XCTAssertFalse(t.visible)
        XCTAssertTrue(t.visibleOrJustHidden(now: 11.5), "隠れる通知が編集の終わりより先に来ても、本人が閉じたと分かる")
        XCTAssertFalse(t.visibleOrJustHidden(now: 12.5))
        // 出ていなかったものの「隠れる」は、直後扱いにしない
        var u = SoftKeyboardTracker()
        u.willHide(isLocal: true, now: 11)
        XCTAssertFalse(u.visibleOrJustHidden(now: 11.1))
    }
}
