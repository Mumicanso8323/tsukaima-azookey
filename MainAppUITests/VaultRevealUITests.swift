//
//  VaultRevealUITests.swift
//  保管庫の「項目を押す → 値を表示」を、偽の値(`--vault-mock`、Face ID は出ない)で確かめる。
//  確かめるのは画面の振る舞い(最初は伏せ字・目のボタンで表示・自動で伏せる・コピーボタンがある)。
//  Face ID 本体とクリップボードの 60 秒は実機で確かめる。
//

import XCTest

final class VaultRevealUITests: XCTestCase {
    private var app: XCUIApplication!
    private let fakePassword = "MOCK-pw-0000-fake"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--vault-mock"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openFanatical() {
        let load = element("vault.load")
        XCTAssertTrue(load.waitForExistence(timeout: 20))
        load.tap()
        let row = element("vault.row.fanatical")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element("vault.password.value").waitForExistence(timeout: 10))
    }

    private func waitForPassword(_ text: String) {
        let p = NSPredicate(format: "label == %@", text)
        let r = XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: element("vault.password.value"))], timeout: 5)
        XCTAssertEqual(r, .completed, "目のボタンで値が出ない")
    }

    private func passwordText() -> String { element("vault.password.value").label }

    func testPasswordStartsMaskedThenEyeShowsThenAutoHides() {
        openFanatical()
        XCTAssertFalse(passwordText().contains(fakePassword), "最初から値が見えている")
        XCTAssertTrue(element("vault.login.value").label.contains("mock-user@example.invalid"))

        element("vault.eye").tap()
        waitForPassword(fakePassword)

        // 試験台は 3 秒で自動的に伏せる
        let masked = NSPredicate(format: "label != %@", fakePassword)
        let exp = expectation(for: masked, evaluatedWith: element("vault.password.value"))
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: 8), .completed, "自動で伏せない")
    }

    func testCopyButtonsExistAndTotpShownForTotpItem() {
        openFanatical()
        XCTAssertTrue(element("vault.login.copy").exists)
        XCTAssertTrue(element("vault.password.copy").exists)
        XCTAssertFalse(element("vault.totp.value").exists, "2FA の無い項目に 6 桁が出ている")
        element("vault.password.copy").tap()
        element("vault.close").tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: element("vault.password.value"))], timeout: 10), .completed)
        let row = element("vault.row.mock-2fa")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element("vault.totp.value").waitForExistence(timeout: 10))
        XCTAssertFalse(element("vault.totp.value").label.contains("123456"), "6 桁が最初から見えている")
    }

    func testBackgroundingMasksPassword() {
        openFanatical()
        element("vault.eye").tap()
        waitForPassword(fakePassword)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        // 背面に回ると画面を閉じて値を捨てる(戻ったら Face ID からやり直し)。値は見えないままのはず
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.staticTexts[fakePassword].exists, "背面から戻ったら値が見えている")
        XCTAssertFalse(element("vault.password.value").exists, "背面に回っても画面が閉じていない")
    }

    // MARK: 履歴・上書きの確認

    private func loadList() {
        let load = element("vault.load")
        XCTAssertTrue(load.waitForExistence(timeout: 20))
        load.tap()
        XCTAssertTrue(element("vault.row.fanatical").waitForExistence(timeout: 10))
    }

    private func typeSite(_ name: String) {
        let f = element("vault.site")
        XCTAssertTrue(f.waitForExistence(timeout: 10))
        f.tap()
        f.typeText(name)
        app.swipeUp()  // 試験台は スクロールでキーボードを閉じる
    }

    func testHistoryShownMaskedInRevealScreen() {
        openFanatical()
        let old = element("vault.history.0.password.value")
        XCTAssertTrue(old.waitForExistence(timeout: 5), "履歴が出ない")
        XCTAssertNotEqual(old.label, "MOCK-old-pw-1111", "履歴のパスワードが最初から見えている")
        element("vault.eye").tap()
        let p = NSPredicate(format: "label == %@", "MOCK-old-pw-1111")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: old)], timeout: 5), .completed)
    }

    func testOverwriteAsksForConfirmation() {
        loadList()
        typeSite("fanatical")
        element("vault.save").tap()
        let overwrite = app.buttons["上書きします(前の値は履歴に残ります)"]
        XCTAssertTrue(overwrite.waitForExistence(timeout: 5), "同じ名前なのに確認が出ない")
        XCTAssertTrue(app.buttons["名前を変える"].exists, "名前を変える選択肢が無い")
        app.buttons["名前を変える"].tap()
        XCTAssertFalse(overwrite.waitForExistence(timeout: 2))
    }

    func testNewNameSavesWithoutConfirmation() {
        loadList()
        typeSite("brand-new-site")
        element("vault.save").tap()
        XCTAssertTrue(element("vault.row.brand-new-site").waitForExistence(timeout: 10), "新しい名前が保存されない")
        XCTAssertFalse(app.buttons["上書きします(前の値は履歴に残ります)"].exists)
    }
}
