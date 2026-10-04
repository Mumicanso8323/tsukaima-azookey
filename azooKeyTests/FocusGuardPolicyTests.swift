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
        // 長く見えたままなら、欄が複数ある画面とみなして戻すのをやめる
        XCTAssertEqual(decide { $0.otherInputVisible = true; $0.waitedTooLong = true }, .abandon)
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
}
