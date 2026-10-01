//
//  ClaudeTabFocusUITests.swift
//  Claude タブの入力欄が「本人が閉じるまでカーソルを離さない」ことをシミュレータで確かめる。
//  アプリは `--claude-mock`(ClaudeMockDriver)で起動し、サーバー無しで 1 秒に 4 件のイベント・ツール状態の更新・
//  busy/idle の切替・セッション一覧の更新・切断→再接続・ターン終了・選択肢の表示を 30 秒流し続ける。
//  その間に打鍵し、1 文字ごとにフォーカスが残っていることを見る。
//  限界: XCUITest で打てるのはソフトウェアキーボード相当(typeText)。Bluetooth キーボード+アプリ内 IME の
//  pressesBegan 経路は実機でしか確かめられない(報告の確認項目)。
//

import XCTest

final class ClaudeTabFocusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--claude-mock"]
        app.launch()
    }

    private var composer: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "claude.composer").firstMatch
    }

    private func hasFocus(_ e: XCUIElement) -> Bool {
        (e.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func openClaudeTab() {
        let tab = app.tabBars.buttons["Claude"]
        if tab.waitForExistence(timeout: 10) {
            tab.tap()
        } else {
            app.buttons["Claude"].firstMatch.tap()
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "入力欄が見つからない")
    }

    private func assertFocused(_ why: String) {
        // 再描画の直後は一瞬だけ外れて次のランループで戻ることがあるので、少しだけ待つ
        let ok = (0..<10).contains { _ in
            if hasFocus(composer) { return true }
            Thread.sleep(forTimeInterval: 0.1)
            return false
        }
        XCTAssertTrue(ok, "フォーカスが外れた: \(why)")
    }

    /// 1 文字ごと・イベントの嵐の最中・送信後・切断/再接続後・選択肢の表示/操作後、のすべてでフォーカスが残る
    func testComposerKeepsFocusThroughTypingEventsSendAndChoices() throws {
        openClaudeTab()
        composer.tap()
        assertFocused("タップ直後")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "キーボードが出ない(シミュレータの Connect Hardware Keyboard を切る)")

        // 10 文字: 1 文字ごとに確認(モックの嵐は起動 3 秒後から 30 秒間)
        for i in 0..<10 {
            composer.typeText("a")
            assertFocused("\(i + 1) 文字目")
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue((composer.value as? String ?? "").contains("aaaaaaaaaa"), "打った文字が入っていない")

        // 送信(Enter 相当はボタン。ソフトキーボードの改行は送信ではない)→ 欄が空になってもフォーカスは残る
        app.buttons["claude.send"].tap()
        assertFocused("送信直後")
        Thread.sleep(forTimeInterval: 0.5)
        assertFocused("送信から 0.5 秒後")

        // 嵐の残り(一覧の更新・busy/idle・切断→再接続・ターン終了・選択肢)の間も 1 秒ごとに確認しつつ打鍵
        let deadline = Date().addingTimeInterval(24)
        var n = 0
        while Date() < deadline {
            composer.typeText("b")
            n += 1
            assertFocused("嵐の最中 \(n) 回目")
            Thread.sleep(forTimeInterval: 1)
        }

        // 選択肢が出ている(モックは起動約 23 秒後に出す)→ ボタンで選んでもフォーカスは残る
        let choice = app.buttons["claude.choice.1"]
        XCTAssertTrue(choice.waitForExistence(timeout: 15), "選択肢が出ない")
        assertFocused("選択肢の表示後")
        choice.tap()
        assertFocused("選択肢を選んだ後")
        XCTAssertTrue(app.buttons["claude.choice.1"].waitForNonExistence(withTimeout: 5), "選択肢が消えない")

        // 状態行が出ている(高さ固定の 1 行)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "claude.toolStatus").firstMatch.exists)
        assertFocused("最後")
    }

    /// 閉じるボタンは明示的な操作なので、押せば閉じて勝手に戻らない
    func testDismissButtonReallyDismisses() throws {
        openClaudeTab()
        composer.tap()
        assertFocused("タップ直後")
        let dismiss = app.buttons["claude.dismiss"]
        guard dismiss.waitForExistence(timeout: 5) else {
            throw XCTSkip("閉じるボタンが無い(ハードウェアキーボード接続扱いのシミュレータ)")
        }
        dismiss.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(hasFocus(composer), "閉じたのに戻ってきた")
    }
}
