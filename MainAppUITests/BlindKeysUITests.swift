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
        XCTAssertTrue(element("blind.listener").exists)
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

        // 行の入れ物(.contain)の識別子は環境で見えないことがあるので、葉の Menu を目印にする。見つからなければ階層を残す。
        let setButton = element("blind.bind.set.228")
        if !setButton.waitForExistence(timeout: 8) {
            XCTFail("blind.bind.set.228 が見つからない。階層:\n\(app.debugDescription)")
            return
        }
        setButton.tap()
        // サブメニューの項目は button / menuItem のどちらで見えるかが環境で違うので、ラベルで探す
        func byLabel(_ label: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        guard byLabel("入る・出る").waitForExistence(timeout: 5) else {
            XCTFail("入る・出る のメニューが出ない。階層:\n\(app.debugDescription)")
            return
        }
        // 診断画面は接続状態の更新で再描画される。その拍にサブメニューへ入る操作が飲まれることがあるので、
        // 入る・出る が一階層目に残っている間だけ(最大 3 回)押し直す。2回押し が出なければ従来どおり失敗にする。
        var drilled = false
        for _ in 0..<3 {
            byLabel("入る・出る").tap()
            if byLabel("2回押し").waitForExistence(timeout: 4) { drilled = true; break }
            if !byLabel("入る・出る").exists { break }
        }
        guard drilled else {
            XCTFail("2回押し が出ない。階層:\n\(app.debugDescription)")
            return
        }
        // 同じ再描画で 2回押し の選択が飲まれることもある。2回押し が残っていて削除ボタンがまだ無い間だけ(最大 3 回)押し直す。
        for _ in 0..<3 {
            byLabel("2回押し").tap()
            if element("blind.bind.delete.228").waitForExistence(timeout: 4) { break }
            if !byLabel("2回押し").exists { break }
        }

        XCTAssertTrue(element("blind.bind.delete.228").waitForExistence(timeout: 5))
        element("blind.bind.delete.228").tap()
        XCTAssertFalse(element("blind.bind.delete.228").waitForExistence(timeout: 2))
    }
}
