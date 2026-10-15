//
//  TsukaimaJapaneseInputUITests.swift
//  日本語を変換しながら打てるか(2026-10-02 本人の報告: 英語は打てるが、変換する日本語は打つと全部消える)。
//  アプリは `--input-lab`(TsukaimaInputLab)で起動する。0.25 秒ごとに画面全体を描き直す中で、
//  「未確定の文字 → 描き直しを何度も挟む → 確定 → 続けて打つ」を行い、文字・フォーカス・バインディングが残るかを見る。
//
//  未確定の文字の入れ方は 2 通り:
//  - 試験台のボタン(lab.mark / lab.unmark)。iOS のキーボードと同じ入口(UITextInput の setMarkedText / unmarkText)を
//    直接呼ぶ。CI のシミュレータでも必ず動くので、こちらを合否の本体にする。
//  - iOS 標準の日本語ローマ字キーボード(地球儀キーで切り替え)。CI のシミュレータには日本語キーボードが登録できない
//    ことがあり、そのときは飛ばす(XCTSkip。飛ばした理由はログに残る)。
//
//  限界: キーボード拡張(使い魔キー)の未確定の文字は実機で確かめる。
//

import XCTest

final class TsukaimaJapaneseInputUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--input-lab"]
        app.launch()
        XCTAssertTrue(element("lab.tick").waitForExistence(timeout: 20))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func value(_ e: XCUIElement) -> String { e.value as? String ?? "" }

    private func hasFocus(_ e: XCUIElement) -> Bool {
        (e.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func focus(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "入力欄が無い", file: file, line: line)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "キーボードが出ない", file: file, line: line)
    }

    // MARK: 本体: setMarkedText で未確定の文字を入れる

    /// 英字を打つ → 未確定「にほんご」→ 描き直しを挟む → 確定 → 続けて打つ
    private func markedTextSurvives(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(id)
        focus(field, file: file, line: line)
        field.typeText("abc ")

        element("lab.mark").tap()
        let composing = value(field)
        XCTAssertTrue(composing.hasPrefix("abc にほんご"), "未確定の文字が入らない: \(composing)", file: file, line: line)

        // 未確定のまま 3 秒(この間に 12 回描き直される)
        Thread.sleep(forTimeInterval: 3)
        let afterWait = value(field)
        XCTAssertTrue(afterWait.hasPrefix("abc にほんご"), "描き直しで未確定の文字が消えた: \(afterWait)", file: file, line: line)
        XCTAssertTrue(hasFocus(field), "描き直しでフォーカスが外れた", file: file, line: line)

        element("lab.unmark").tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(value(field).hasPrefix("abc にほんご"), "確定したら消えた: \(value(field))", file: file, line: line)

        field.typeText("x")
        Thread.sleep(forTimeInterval: 1)
        let final = value(field)
        XCTAssertEqual(final, "abc にほんごx", "確定の後に打った文字の位置がずれた/前の文字が消えた", file: file, line: line)
        XCTAssertTrue(hasFocus(field), "確定の後にフォーカスが外れた", file: file, line: line)
        let binding = element(id + ".binding").label
        XCTAssertTrue(binding.contains("abc にほんごx"), "確定した文字がバインディングに入っていない: \(binding)", file: file, line: line)
    }

    /// アンケート・Claude タブ・チャットの入力欄(TsukaimaComposerField)
    func testComposerFieldKeepsMarkedText() {
        markedTextSurvives("lab.composer")
    }

    /// メモ・下書きの複数行(TsukaimaTextEditor)
    func testTextEditorKeepsMarkedText() {
        markedTextSurvives("lab.editor")
    }

    /// 比較: SwiftUI の TextField(axis: .vertical)。直す前のアンケートが使っていた部品。
    /// 結果を記録するだけ(失敗にしない)。描き直しで消える現象がシミュレータでも出るかの手がかり。
    func testBaselineSwiftUIVerticalTextField() {
        let field = element("lab.swiftuiVertical")
        focus(field)
        field.typeText("abc ")
        element("lab.mark").tap()
        let composing = value(field)
        Thread.sleep(forTimeInterval: 3)
        let afterWait = value(field)
        element("lab.unmark").tap()
        Thread.sleep(forTimeInterval: 1)
        let confirmed = value(field)
        let report = "SwiftUI 縦 TextField: 入力直後=\(composing) / 3 秒後=\(afterWait) / 確定後=\(confirmed) / フォーカス=\(hasFocus(field))"
        print("BASELINE: " + report)
        XCTContext.runActivity(named: report) { _ in }
    }

    // MARK: 参考: iOS 標準の日本語ローマ字キーボードで打つ(切り替えられないときは飛ばす)

    /// 地球儀キーで日本語ローマ字キーボードに切り替える("a" を打って「あ」になるかで確かめる)
    private func switchToJapanese(_ field: XCUIElement) throws {
        for _ in 0..<4 {
            field.typeText("a")
            let v = value(field)
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            if v.hasSuffix("あ") {
                if !value(field).isEmpty { field.typeText(XCUIKeyboardKey.delete.rawValue) }
                return
            }
            let globe = app.keyboards.buttons["Next keyboard"].exists ? app.keyboards.buttons["Next keyboard"] : app.keyboards.buttons["次のキーボード"]
            guard globe.exists else { break }
            globe.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        let labels = app.keyboards.buttons.allElementsBoundByIndex.prefix(40).map { $0.label }.joined(separator: ",")
        throw XCTSkip("日本語ローマ字キーボードに切り替えられない(このシミュレータに登録されていない。キーボードのボタン: \(labels))")
    }

    private func typeJapaneseWithKeyboard(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let field = element(id)
        focus(field, file: file, line: line)
        try switchToJapanese(field)

        field.typeText("nihongo")
        let composing = value(field)
        XCTAssertTrue(composing.contains("にほんご") || composing.contains("日本語"), "未確定の文字が見えない: \(composing)", file: file, line: line)
        Thread.sleep(forTimeInterval: 3)
        let afterWait = value(field)
        XCTAssertTrue(afterWait.contains("にほんご") || afterWait.contains("日本語"), "描き直しで未確定の文字が消えた: \(afterWait)", file: file, line: line)
        field.typeText("\n")
        Thread.sleep(forTimeInterval: 2)
        field.typeText("desu")
        Thread.sleep(forTimeInterval: 1.5)
        field.typeText("\n")
        Thread.sleep(forTimeInterval: 2)
        let final = value(field)
        XCTAssertTrue(final.hasPrefix("にほんご") || final.hasPrefix("日本語"), "1 回目の分が消えた: \(final)", file: file, line: line)
        XCTAssertTrue(final.hasSuffix("です") || final.hasSuffix("デス"), "2 回目の確定で消えた/ずれた: \(final)", file: file, line: line)
        XCTAssertTrue(hasFocus(field), "確定の後にフォーカスが外れた", file: file, line: line)
    }

    func testComposerFieldWithJapaneseKeyboard() throws {
        try typeJapaneseWithKeyboard("lab.composer")
    }
}
