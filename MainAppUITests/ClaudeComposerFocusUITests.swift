//
//  ClaudeComposerFocusUITests.swift
//  Claude タブの入力欄が、打つ・消す・カーソル移動・選択・画面の更新・ポーリング・キーボードの出し入れ・
//  背面→前面のどれでも、フォーカスとカーソル位置を保つことをシミュレータで確かめる。
//
//  アプリは `--claude-mock --claude-mock-stream` で起動する(ClaudeMockDriver: サーバーの代わりに
//  0.3 秒ごとにイベントを流し続け、セッション一覧も取るたびに変わる)。
//  画面の見えない札 `claude.debug.focus`(ClaudeFocusProbe)が入力欄の編集開始・終了の回数を数えるので、
//  一瞬外れて付け直された場合も end が増えて失敗する。
//
//  限界: typeText はソフトウェアキーボード相当。Bluetooth キーボード+アプリ内 IME の経路と、
//  キーボード拡張(使い魔キー)の未確定文字は実機でしか確かめられない。
//

import XCTest

final class ClaudeComposerFocusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--claude-mock", "--claude-mock-stream"]
    }

    // MARK: 補助

    private func launch(plainField: Bool = false) {
        if plainField {
            // 物理キーボード用 IME を切った設定(SwiftUI の TextField 版の入力欄)
            app.launchArguments += ["-tsukaima.hwime.enabled", "NO"]
        }
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "入力欄が見つからない")
    }

    private var composer: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "claude.composer").firstMatch
    }

    private var probe: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "claude.debug.focus").firstMatch
    }

    private var value: String { composer.value as? String ?? "" }

    private func hasFocus() -> Bool {
        (composer.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// 編集開始・終了の回数(ClaudeFocusProbe)
    private func probeCounts() -> (begin: Int, end: Int) {
        let label = probe.label
        func num(_ key: String) -> Int {
            guard let r = label.range(of: key + "=") else { return -1 }
            return Int(label[r.upperBound...].prefix { $0.isNumber }) ?? -1
        }
        return (num("begin"), num("end"))
    }

    private func focusComposer() {
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "ソフトウェアキーボードが出ない(シミュレータの Connect Hardware Keyboard を切る)")
        XCTAssertTrue(hasFocus(), "タップしてもフォーカスが付かない")
    }

    /// フォーカスが今ある・一度も外れていない(end が増えていない)ことを、待たずにその場で確かめる。
    private func assertStillFocused(_ why: String, endsAllowed: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(hasFocus(), "フォーカスが外れた: \(why)", file: file, line: line)
        let c = probeCounts()
        XCTAssertEqual(c.end, endsAllowed, "編集が終了した(外れて付け直された)回数: \(why) [\(probe.label)]", file: file, line: line)
    }

    private func typeSlowly(_ s: String, check why: String) {
        for (i, ch) in s.enumerated() {
            composer.typeText(String(ch))
            assertStillFocused("\(why) \(i + 1) 文字目")
        }
    }

    private func deleteKey(_ n: Int) {
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: n))
    }

    /// 入力欄の先頭(左上の文字の手前)をタップしてカーソルを動かす
    private func tapStartOfText() {
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 12, dy: 0)).tap()
    }

    // MARK: テスト

    /// 1. 画面が更新され続けている最中に 30 文字以上打つ(1 文字ごとにフォーカスと文字を確かめる)
    func test1_TypeThirtyPlusCharactersWhileStreaming() throws {
        launch()
        focusComposer()
        let text = "the quick brown fox jumps over the lazy dog 42"
        XCTAssertGreaterThanOrEqual(text.count, 30)
        typeSlowly(text, check: "打鍵")
        XCTAssertEqual(value, text, "打った文字がそのまま残っていない")
        assertStillFocused("打ち終わり")
    }

    /// 2. 文字を消す(1 文字ずつ・まとめて)
    func test2_DeleteKeepsFocusAndText() throws {
        launch()
        focusComposer()
        composer.typeText("hello world 12345")
        for i in 0..<5 {
            deleteKey(1)
            assertStillFocused("1 文字消した \(i + 1) 回目")
        }
        XCTAssertEqual(value, "hello world ")
        deleteKey(6)
        assertStillFocused("まとめて消した")
        XCTAssertEqual(value, "hello ")
        composer.typeText("again")
        XCTAssertEqual(value, "hello again")
        assertStillFocused("消した後に打つ")
    }

    /// 3. 途中にカーソルを移して打ち続ける(更新が流れている間に数秒待ってもカーソル位置が保たれる)
    func test3_MoveCursorThenKeepTyping() throws {
        launch()
        focusComposer()
        composer.typeText("world is here")
        tapStartOfText()
        assertStillFocused("先頭をタップしてカーソル移動")
        composer.typeText("A")
        XCTAssertEqual(value, "Aworld is here", "カーソルが先頭に移っていない")
        Thread.sleep(forTimeInterval: 3)   // この間もイベントが流れ続け、画面が何度も描き直される
        composer.typeText("BC")
        XCTAssertEqual(value, "ABCworld is here", "更新のあいだにカーソル位置が動いた")
        deleteKey(1)
        XCTAssertEqual(value, "ABworld is here", "途中で消すと別の位置が消えた")
        assertStillFocused("途中で打つ・消す")
    }

    /// 3b. 選択(ダブルタップで単語を選ぶ)が更新のあいだも保たれ、打つと置き換わる
    func test3b_SelectionSurvivesUpdates() throws {
        launch()
        focusComposer()
        composer.typeText("alpha beta")
        tapStartOfText()
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 20, dy: 0)).doubleTap()
        assertStillFocused("単語を選択")
        Thread.sleep(forTimeInterval: 2)
        composer.typeText("Z")
        XCTAssertEqual(value, "Z beta", "選択が更新で外れた(置き換わらなかった)")
        assertStillFocused("選択を置き換えた")
    }

    /// 4. ポーリング(15 秒ごとのセッション一覧)とイベントが流れたまま 60 秒以上待っても外れない
    func test4_SixtySecondsOfPollingKeepsFocus() throws {
        launch()
        focusComposer()
        composer.typeText("before wait")
        let deadline = Date().addingTimeInterval(65)
        var n = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 5)
            n += 1
            assertStillFocused("待機 \(n * 5) 秒")
        }
        composer.typeText(" after")
        XCTAssertEqual(value, "before wait after")
        assertStillFocused("待機後に打つ")
    }

    /// 5. アプリを裏に回して戻っても、フォーカスと文字とカーソル位置が保たれる
    func test5_BackgroundAndReturnKeepsFocus() throws {
        launch()
        focusComposer()
        composer.typeText("keep me")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(value, "keep me", "裏に回して戻ったら文字が消えた")
        // 裏に回る間は iOS がキーボードを一旦しまう(編集終了が 1 回来ることがある)。戻ったら元の欄に戻っていること。
        let deadline = Date().addingTimeInterval(5)
        while !hasFocus() && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(hasFocus(), "戻ったときにフォーカスが入力欄に戻っていない")
        composer.typeText(" ok")
        XCTAssertEqual(value, "keep me ok", "戻った後の文字が末尾に入らない")
        let before = probeCounts().end
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(probeCounts().end, before, "戻った後の更新で外れた")
        XCTAssertTrue(hasFocus())
    }

    /// 6. キーボードを自分でしまって、もう一度出す。しまう操作以外では外れず、文字も残る
    func test6_KeyboardHideAndShow() throws {
        launch()
        focusComposer()
        composer.typeText("draft text")
        // 履歴を下へ引っぱってキーボードをしまう(本人の明示的な操作)
        let timeline = app.scrollViews["claude.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        timeline.swipeDown()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(value, "draft text", "キーボードをしまったら文字が消えた")
        let endsAfterHide = probeCounts().end
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(hasFocus(), "しまったのに勝手にフォーカスが戻った")
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(hasFocus())
        composer.typeText(" more")
        XCTAssertEqual(value, "draft text more")
        Thread.sleep(forTimeInterval: 3)
        assertStillFocused("出し直した後", endsAllowed: endsAfterHide)
    }

    /// 7. 送信してもキーボードは出たまま(公式アプリと同じ)・欄は空になり、送った文が履歴に出る
    func test7_SendKeepsKeyboard() throws {
        launch()
        focusComposer()
        composer.typeText("send this please")
        app.buttons["claude.send"].tap()
        XCTAssertEqual(value.isEmpty || value == composer.placeholderValue, true, "送信後に欄が空にならない")
        assertStillFocused("送信直後")
        XCTAssertTrue(app.staticTexts["send this please"].waitForExistence(timeout: 5), "送った文が履歴に出ない")
        composer.typeText("next")
        XCTAssertEqual(value, "next")
        assertStillFocused("送信後に続けて打つ")
    }

    /// 8. 物理キーボード用 IME をオフにした設定(SwiftUI の TextField 版)でも同じく外れない
    func test8_PlainFieldKeepsFocusWhileStreaming() throws {
        launch(plainField: true)
        focusComposer()
        let text = "plain field typing over thirty chars"
        typeSlowly(text, check: "TextField 版")
        XCTAssertEqual(value, text)
        deleteKey(5)
        assertStillFocused("TextField 版で消す")
        Thread.sleep(forTimeInterval: 20)
        assertStillFocused("TextField 版で 20 秒待つ")
    }
}
