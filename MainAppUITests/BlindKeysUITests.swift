import XCTest

final class BlindKeysUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // 起動時の権限確認・常駐同期を避け、使い魔タブの導線だけを確かめる。
        app.launchArguments = ["--claude-mock"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testBlindScreenHasMinimalControls() {
        XCTAssertTrue(app.tabBars.buttons["使い魔"].waitForExistence(timeout: 20))
        app.tabBars.buttons["使い魔"].tap()
        XCTAssertTrue(app.buttons["ブラインド"].waitForExistence(timeout: 10))
        app.buttons["ブラインド"].tap()

        XCTAssertTrue(element("blind.status").waitForExistence(timeout: 10))
        XCTAssertTrue(element("blind.close").exists)
        XCTAssertTrue(element("blind.diag.toggle").exists)
        element("blind.diag.toggle").tap()
        XCTAssertTrue(element("blind.diag.list").waitForExistence(timeout: 5))
    }

    /// 本物のキーが無くても、--blind-mock-keys の診断行から合図を割り当て・消せる。
    func testAssignAndDeleteBindingFromDiagnostics() {
        app.terminate()
        app.launchArguments = ["--claude-mock", "--blind-mock-keys"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["使い魔"].waitForExistence(timeout: 20))
        app.tabBars.buttons["使い魔"].tap()
        XCTAssertTrue(app.buttons["ブラインド"].waitForExistence(timeout: 10))
        app.buttons["ブラインド"].tap()
        XCTAssertTrue(element("blind.diag.toggle").waitForExistence(timeout: 10))
        element("blind.diag.toggle").tap()

        XCTAssertTrue(element("blind.bind.row.228").waitForExistence(timeout: 5))
        element("blind.bind.set.228").tap()
        XCTAssertTrue(app.buttons["入る・出る"].waitForExistence(timeout: 5))
        app.buttons["入る・出る"].tap()
        XCTAssertTrue(app.buttons["2回押し"].waitForExistence(timeout: 5))
        app.buttons["2回押し"].tap()

        XCTAssertTrue(element("blind.bind.delete.228").waitForExistence(timeout: 5))
        element("blind.bind.delete.228").tap()
        XCTAssertFalse(element("blind.bind.delete.228").waitForExistence(timeout: 2))
    }
}
