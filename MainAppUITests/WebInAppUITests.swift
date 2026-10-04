import XCTest

final class WebInAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // --web-mock-page: ネットワークに出ず、ローカルの確認用ページを WebView に読ませる(Cookie 経路は通す)
        app.launchArguments = ["--claude-mock", "--web-mock-page"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func byText(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    func testKeyboardCatalogOpensInAppWebView() {
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
        XCTAssertTrue(element("web.close").exists)
        // Safari に飛ばず、アプリが前面のまま
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertNotEqual(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").state, .runningForeground)

        XCTAssertTrue(byText("fixture-ready").waitForExistence(timeout: 15), "確認用ページが読めていない")
        // Cookie の属性はネイティブで読み戻した結果を見る(値は出さない)
        let st = element("web.cookie.state")
        XCTAssertTrue(st.waitForExistence(timeout: 15))
        XCTAssertEqual(st.label, "name=device_token;httpOnly=true;secure=true;persistent=false")
        // JS からは見えない(HttpOnly)
        XCTAssertTrue(byText("cookie-js:[]").waitForExistence(timeout: 10), "JS から Cookie が見えている、またはページが読めていない")
        XCTAssertFalse(byText("MOCKTOKEN").exists)

        // 外付けキーボードの和音の配送は CI のシミュレーターでは確かめられない(XCUIElement.typeKey は macOS 専用)

        element("web.close").tap()
        XCTAssertTrue(app.buttons["生活"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("web.close").waitForNonExistence(timeout: 5))
    }
}
