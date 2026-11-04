import XCTest

/// 設定の「引き継ぎ用に書き出す」から、合言葉 → 書き出し → 共有シートが出るところまで。
final class TransferUITests: XCTestCase {
    func testExportShowsShareSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--claude-mock", "--transfer-mock"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["使い魔"].waitForExistence(timeout: 20))
        app.tabBars.buttons["使い魔"].tap()
        let tabs = app.descendants(matching: .any).matching(identifier: "tsukaima.innerTabs").firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        tabs.buttons["端末"].tap()

        let export = app.descendants(matching: .any).matching(identifier: "transfer.export").firstMatch
        for _ in 0..<6 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 10), "書き出すボタンが無い")
        export.tap()

        let field = app.textFields["transfer.export.passphrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("uitest-passphrase")
        app.buttons["transfer.export.run"].tap()

        let share = app.descendants(matching: .any).matching(identifier: "transfer.share").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 30), "書き出し後に共有ボタンが出ない")
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        let copy = app.buttons["Copy"]
        let close = app.buttons["Close"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15) || copy.waitForExistence(timeout: 5) || close.waitForExistence(timeout: 5),
                      "共有シートが出ない")
    }
}
