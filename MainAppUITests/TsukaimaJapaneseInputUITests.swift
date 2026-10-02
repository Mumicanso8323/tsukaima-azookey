//
//  TsukaimaJapaneseInputUITests.swift
//  日本語を変換しながら打てるか(2026-10-02 本人の報告: 英語は打てるが、変換する日本語は打つと全部消える)。
//  アプリは `--input-lab`(TsukaimaInputLab)で起動する。0.25 秒ごとに画面全体を描き直す中で、
//  iOS 標準の日本語ローマ字キーボードで「未確定の文字 → 描き直しを何度も挟む → 確定」を行い、文字が残るかを見る。
//
//  限界: 使うのは iOS 標準の日本語キーボード。使い魔キー(キーボード拡張)の未確定の文字は実機で確かめる。
//

import XCTest

final class TsukaimaJapaneseInputUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // 日本語(ローマ字)キーボードは CI がシミュレータに登録しておく(英語の次)。テストの中で地球儀キーで切り替える
        app.launchArguments = ["--input-lab"]
        app.launch()
        XCTAssertTrue(app.staticTexts["lab.tick"].waitForExistence(timeout: 20) || element("lab.tick").waitForExistence(timeout: 5))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func value(_ e: XCUIElement) -> String { e.value as? String ?? "" }

    private func hasFocus(_ e: XCUIElement) -> Bool {
        (e.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// 地球儀キーで日本語ローマ字キーボードに切り替える(試しに "a" を打って「あ」になるかで確かめる)
    private func switchToJapanese(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<4 {
            field.typeText("a")
            let v = value(field)
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            if v.hasSuffix("あ") {
                // 未確定の「あ」を消し切る
                if !value(field).isEmpty { field.typeText(XCUIKeyboardKey.delete.rawValue) }
                return
            }
            let globe = app.keyboards.buttons["Next keyboard"].exists ? app.keyboards.buttons["Next keyboard"] : app.keyboards.buttons["次のキーボード"]
            guard globe.exists else { break }
            globe.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        let labels = app.keyboards.buttons.allElementsBoundByIndex.prefix(40).map(\.label).joined(separator: ",")
        XCTFail("日本語ローマ字キーボードに切り替えられない(キーボードのボタン: \(labels))", file: file, line: line)
    }

    /// 未確定のまま描き直しを何度も挟んでから確定し、続けて打つ。文字・フォーカス・バインディングが保たれること。
    private func composeAndConfirm(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(id)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "\(id) が無い", file: file, line: line)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "キーボードが出ない", file: file, line: line)
        switchToJapanese(field, file: file, line: line)

        field.typeText("nihongo")
        let composing = value(field)
        XCTAssertFalse(composing.contains("nihongo"),
                       "日本語のキーボードになっていない(ローマ字がそのまま入った: \(composing))", file: file, line: line)
        XCTAssertTrue(composing.contains("にほんご") || composing.contains("日本語"),
                      "未確定の文字が見えない: \(composing)", file: file, line: line)

        // 未確定のまま 3 秒(この間に 12 回描き直される)
        Thread.sleep(forTimeInterval: 3)
        let afterWait = value(field)
        XCTAssertTrue(afterWait.contains("にほんご") || afterWait.contains("日本語"),
                      "描き直しで未確定の文字が消えた: \(afterWait)", file: file, line: line)
        XCTAssertTrue(hasFocus(field), "描き直しでフォーカスが外れた", file: file, line: line)

        // 確定(日本語キーボードの改行キー=確定)
        field.typeText("\n")
        Thread.sleep(forTimeInterval: 2)
        let confirmed = value(field)
        XCTAssertTrue(confirmed.hasPrefix("にほんご") || confirmed.hasPrefix("日本語"), "確定したら消えた: \(confirmed)", file: file, line: line)

        // 続けて打って確定(1 回目の確定分が残ったまま後ろに足される)
        field.typeText("desu")
        Thread.sleep(forTimeInterval: 1.5)
        field.typeText("\n")
        Thread.sleep(forTimeInterval: 2)
        let final = value(field)
        XCTAssertTrue(final.hasSuffix("です") || final.hasSuffix("デス"), "2 回目の確定で消えた/ずれた: \(final)", file: file, line: line)
        XCTAssertTrue(final.hasPrefix("にほんご") || final.hasPrefix("日本語"), "1 回目の分が消えた: \(final)", file: file, line: line)
        XCTAssertTrue(hasFocus(field), "確定の後にフォーカスが外れた", file: file, line: line)

        // バインディング(送信ボタンが読む値)にも確定した文字が入っている
        let binding = element(id + ".binding").label
        XCTAssertTrue(binding.contains("です") || binding.contains("デス"), "確定した文字がバインディングに入っていない: \(binding)", file: file, line: line)
    }

    /// アンケート・Claude タブ・チャットの入力欄(TsukaimaComposerField)
    func testComposerFieldKeepsJapaneseComposition() {
        composeAndConfirm("lab.composer")
    }

    /// メモ・下書きの複数行(TsukaimaTextEditor)
    func testTextEditorKeepsJapaneseComposition() {
        composeAndConfirm("lab.editor")
    }

    /// 比較: SwiftUI の TextField(axis: .vertical)。直す前のアンケートが使っていた部品。
    /// 結果を記録するだけ(落ちても失敗にしない)。描き直しで消える現象がシミュレータでも出るかの手がかりにする。
    func testBaselineSwiftUIVerticalTextField() {
        let field = element("lab.swiftuiVertical")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 5) else { return }
        switchToJapanese(field)
        field.typeText("nihongo")
        let composing = value(field)
        Thread.sleep(forTimeInterval: 3)
        let afterWait = value(field)
        field.typeText("\n")
        Thread.sleep(forTimeInterval: 2)
        let confirmed = value(field)
        let report = "SwiftUI 縦 TextField: 入力直後=\(composing) / 3 秒後=\(afterWait) / 確定後=\(confirmed)"
        print("BASELINE: " + report)
        XCTContext.runActivity(named: report) { _ in }
    }
}
