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
        let expected = "name=device_token;httpOnly=true;secure=true;persistent=true"
        // 読み戻しは非同期で、最初は "pending"。期待のラベルになるまで待つ
        let deadline = Date().addingTimeInterval(15)
        while st.label != expected && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertEqual(st.label, expected)
        // JS からは見えない(HttpOnly)
        XCTAssertTrue(byText("cookie-js:[]").waitForExistence(timeout: 10), "JS から Cookie が見えている、またはページが読めていない")
        XCTAssertFalse(byText("MOCKTOKEN").exists)

        // 外付けキーボードの和音の配送は CI のシミュレーターでは確かめられない(XCUIElement.typeKey は macOS 専用)

        element("web.close").tap()
        XCTAssertTrue(element("web.close").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["生活"].waitForExistence(timeout: 10))
    }
    /// 生活タブの Web 行を探す(必要なら上へスクロール)
    private func lifeRow(_ title: String) -> XCUIElement {
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 20))
        app.tabBars.buttons["ホーム"].tap()
        XCTAssertTrue(app.buttons["生活"].waitForExistence(timeout: 10))
        app.buttons["生活"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        var tries = 0
        while !row.exists && tries < 10 {
            app.swipeUp()
            tries += 1
        }
        return row
    }

    func testProbeAndForgeRowsExistInLifeTab() {
        let probe = lifeRow("モデル試験の文")
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "モデル試験の文の行が無い。階層:\n\(app.debugDescription)")
        let forge = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "forge(ゲーム制作の部屋)")).firstMatch
        var tries = 0
        while !forge.exists && tries < 6 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(forge.waitForExistence(timeout: 5), "forge の行が無い")
        forge.tap()

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15) || element("web.view").exists, "アプリ内 WebView が出ない")
        XCTAssertTrue(element("web.close").exists)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(byText("fixture-ready").waitForExistence(timeout: 15), "確認用ページが読めていない")
        // 署名の橋: 許可リストの forge 送信は通り、リスト外のパス・iframe からの要求は断られる
        XCTAssertTrue(byText("signallow:ok").waitForExistence(timeout: 15), "forge の送信の署名が通らない(または橋に差し替わっていない)")
        XCTAssertTrue(byText("signdeny:denied").waitForExistence(timeout: 15), "許可リスト外のパスが断られていない")
        XCTAssertTrue(byText("signiframe:denied").waitForExistence(timeout: 15), "iframe からの署名要求が断られていない")
        element("web.close").tap()
        XCTAssertTrue(element("web.close").waitForNonExistence(timeout: 5))
    }
}
