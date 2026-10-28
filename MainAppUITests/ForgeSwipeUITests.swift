import XCTest

/// forge の部屋(生活タブ → forge)の、UI のない部分のスワイプ。
/// 縦から 50 度までの動きは Web のログのスクロールになり、閉じる・タブ移動・戻るが起きないこと。
/// 確認用ページ(--web-mock-page。ネットワークなし)の #log が、本物の forge.html と同じ作りで縦にスクロールする。
final class ForgeSwipeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--claude-mock", "--web-mock-page"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openForge() {
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 20))
        app.tabBars.buttons["ホーム"].tap()
        XCTAssertTrue(app.buttons["生活"].waitForExistence(timeout: 10))
        app.buttons["生活"].tap()
        let forge = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "forge(ゲーム制作の部屋)")).firstMatch
        var tries = 0
        while !forge.exists && tries < 12 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(forge.waitForExistence(timeout: 5), "forge の行が無い")
        forge.tap()
        XCTAssertTrue(element("web.close").waitForExistence(timeout: 15))
        XCTAssertTrue(logTopElement().waitForExistence(timeout: 15), "確認用ページ(#log)が読めていない")
    }

    private func logTopElement() -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "logtop:")).firstMatch
    }

    private func logTop() -> Int {
        let label = logTopElement().label
        return Int(label.replacingOccurrences(of: "logtop:", with: "")) ?? -1
    }

    /// 指が上へ動く向き(= 内容は下へ進む)で、縦から angle 度ずらした長さ length の動き。angle 90 は真横
    private func swipe(angle: Double, length: Double = 180) {
        let web = app.webViews.firstMatch.exists ? app.webViews.firstMatch : element("web.view")
        let f = web.frame
        let rad = angle * Double.pi / 180
        let dx = length * sin(rad)
        let dy = -length * cos(rad)
        // 空き領域(ログの下半分)の中。右へ動く横成分に収まるよう左寄りから始める
        let startX = f.minX + 24
        let startY = f.minY + f.height * 0.78
        let origin = web.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: startX - f.minX, dy: startY - f.minY))
        let end = origin.withOffset(CGVector(dx: startX - f.minX + dx, dy: startY - f.minY + dy))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func assertContainerIntact(_ context: String) {
        XCTAssertTrue(element("web.close").exists, "\(context): 部屋が閉じた/戻った")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testVerticalishSwipesScrollTheLogAndKeepTheContainer() {
        openForge()
        for angle in [0.0, 30.0, 50.0] {
            let before = logTop()
            XCTAssertGreaterThanOrEqual(before, 0)
            swipe(angle: angle)
            let deadline = Date().addingTimeInterval(5)
            while logTop() <= before && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            XCTAssertGreaterThan(logTop(), before, "縦から \(Int(angle)) 度のスワイプでログがスクロールしない")
            assertContainerIntact("\(Int(angle)) 度")
        }
    }

    /// 70 度・真横(90 度)は、ログが動くかは問わない(横寄り)。ただ部屋が閉じない・別のタブへ移らないことは確かめる。
    /// forge の部屋は全画面カバーで、親に横スワイプの動作は無い(閉じるボタンだけ)。
    func testHorizontalishSwipesDoNotDismissOrSwitchTab() {
        openForge()
        for angle in [70.0, 90.0] {
            swipe(angle: angle)
            Thread.sleep(forTimeInterval: 0.6)
            assertContainerIntact("\(Int(angle)) 度")
            XCTAssertTrue(logTopElement().exists)
        }
        // 反対向き(左へ)の真横も同じ
        let web = app.webViews.firstMatch.exists ? app.webViews.firstMatch : element("web.view")
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)))
        Thread.sleep(forTimeInterval: 0.6)
        assertContainerIntact("左への真横")
        element("web.close").tap()
        XCTAssertTrue(element("web.close").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["生活"].waitForExistence(timeout: 10), "閉じたあと生活タブに戻る")
    }
}
