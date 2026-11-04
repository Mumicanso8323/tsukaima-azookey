import XCTest

/// 英数キー(Lang2)を、アプリが受けて WebView のページへ keydown → keyup の順で届ける経路。
/// UI テストからは本物のハードウェアキーを送れないので、--tap-mock-lang-press で実機の pressesBegan と同じ共通処理へ
/// 合成の押下を流す。実機の UIPress の配送そのものは、ハードウェアキーボードのある実機でしか確かめられない。
final class TapLangKeyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--claude-mock", "--web-mock-page", "--tap-mock-lang-press"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func byText(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    func testLang2PressReachesPageAsKeydownThenKeyup() {
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 20))
        app.tabBars.buttons["ホーム"].tap()
        XCTAssertTrue(app.buttons["生活"].waitForExistence(timeout: 10))
        app.buttons["生活"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "キーボード カタログ")).firstMatch
        var tries = 0
        while !row.exists && tries < 8 {
            app.swipeUp()
            tries += 1
        }
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("キーボード カタログの行が見つからない。階層:\n\(app.debugDescription)")
            return
        }
        row.tap()

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15) || element("web.view").exists, "アプリ内 WebView が出ない")
        XCTAssertTrue(byText("fixture-ready").waitForExistence(timeout: 15), "確認用ページが読めていない")
        // 順序まで一致(keydown の後に keyup)
        XCTAssertTrue(byText("langlog:down:Lang2,up:Lang2").waitForExistence(timeout: 20), "ページが Lang2 の keydown → keyup を記録していない")

        element("web.close").tap()
        XCTAssertTrue(element("web.close").waitForNonExistence(timeout: 5))
    }
}
