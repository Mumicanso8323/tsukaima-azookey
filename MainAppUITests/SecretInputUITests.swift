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

    func testBothAreSecureFields() {
        let pw = app.secureTextFields["vault.password"]
        XCTAssertTrue(pw.waitForExistence(timeout: 20), "パスワード欄が伏せ字欄でない")
        // 鍵の欄も伏せ字(画面に鍵を出さない)。種別は .oneTimeCode で、新規パスワードと見なされない
        XCTAssertTrue(app.secureTextFields["vault.totp"].exists, "2 段階認証の鍵が伏せ字欄でない")
        XCTAssertFalse(app.textFields["vault.totp"].exists, "2 段階認証の鍵が平文の欄になっている")
    }

    func testBothValuesSurviveSwitchingFields() {
        let pw = app.secureTextFields["vault.password"]
        XCTAssertTrue(pw.waitForExistence(timeout: 20))
        scrollTo(pw)
        pw.tap()
        pw.typeText("MOCKpw1")
        let key = app.secureTextFields["vault.totp"]
        scrollTo(key)
        key.tap()
        key.typeText("MOCKKEY234")
        // 伏せ字の value は入力した文字数ぶんの点になる
        XCTAssertEqual((key.value as? String)?.count, 10, "鍵の入力が入っていない")
        XCTAssertEqual((pw.value as? String)?.count, 7, "鍵の欄に移るとパスワード欄の入力が消える")
        pw.tap()
        XCTAssertEqual((key.value as? String)?.count, 10, "パスワード欄に戻ると鍵が消える")
        XCTAssertEqual((pw.value as? String)?.count, 7)
    }
}
