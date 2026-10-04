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
        XCTAssertEqual(decide { $0.otherInputVisible = true }, .abandon)
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
