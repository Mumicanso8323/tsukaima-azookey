//
//  SecretInputUITests.swift
//  保管庫の登録欄(パスワードと 2 段階認証の鍵)の入力を、試験台(`--vault-mock`)で確かめる。
//  実機では「強力なパスワードを使用」の提案が出て、×で閉じると隣の欄が消えていた。
//  提案そのものはシミュレータでは出せないので、原因を断つ設定(欄の種類)と、
//  両方の欄に入れた値が互いに消えないことを確かめる。提案を閉じる操作は実機で確かめる。
//

import XCTest

final class SecretInputUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--vault-mock"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func scrollTo(_ el: XCUIElement) {
        var n = 0
        while !el.isHittable && n < 6 { app.swipeUp(); n += 1 }
        XCTAssertTrue(el.isHittable, "欄が画面に出ない")
    }

    func testPasswordIsSecureAndKeyIsPlainField() {
        let pw = app.secureTextFields["vault.password"]
        XCTAssertTrue(pw.waitForExistence(timeout: 20), "パスワード欄が伏せ字欄でない")
        // 鍵の欄が伏せ字欄だと、2 つ並んで iOS が新規パスワード登録と見なす
        XCTAssertFalse(app.secureTextFields["vault.totp"].exists, "2 段階認証の鍵が伏せ字欄のまま")
        XCTAssertTrue(app.textFields["vault.totp"].exists)
        XCTAssertEqual(app.secureTextFields.count, 1, "伏せ字欄が複数並んでいる")
    }

    func testBothValuesSurviveSwitchingFields() {
        let pw = app.secureTextFields["vault.password"]
        XCTAssertTrue(pw.waitForExistence(timeout: 20))
        scrollTo(pw)
        pw.tap()
        pw.typeText("MOCKpw1")
        let key = app.textFields["vault.totp"]
        scrollTo(key)
        key.tap()
        key.typeText("MOCKKEY234")
        XCTAssertEqual(key.value as? String, "MOCKKEY234")
        // 鍵の欄に移ったあとも、パスワード欄に入力が残っている(伏せ字は点の列になる)
        let pwValue = (pw.value as? String) ?? ""
        XCTAssertFalse(pwValue.isEmpty, "鍵の欄に移るとパスワード欄が空になる")
        XCTAssertNotEqual(pwValue, "パスワード(変えないなら空欄)", "パスワード欄が空のまま")
        // 戻っても鍵が残る
        pw.tap()
        XCTAssertEqual(key.value as? String, "MOCKKEY234", "パスワード欄に戻ると鍵が消える")
    }
}
