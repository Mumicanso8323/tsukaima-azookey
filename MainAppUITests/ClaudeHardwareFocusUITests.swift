//
//  ClaudeHardwareFocusUITests.swift
//  物理キーボード接続中(`--claude-hw-keyboard` で接続中として扱う)の FocusGuard を確かめる。
//  - システムがフォーカスを奪っても、入力欄に戻って打ち続けられる(strong な「一度も外れない」ではなく、すぐ戻る)。
//  - 履歴をスクロールしても、キーボードもフォーカスも外れない。
//
//  限界: 本物の Bluetooth キーボード・シート表示の直前の順序・フルキーボードアクセスの Tab は実機でしか確かめられない。
//

import XCTest

final class ClaudeHardwareFocusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--claude-mock", "--claude-mock-stream", "--claude-hw-keyboard"]
    }

    override func tearDownWithError() throws {
        // 次のテストへ、奪うタイマや戻した回数が残らないよう、アプリを確実に終わらせる
        app.terminate()
    }

    /// 奪う動作はアプリ側のタイマ(UI のボタンは押せなかったので使わない)。interval 秒ごと、max 回奪えたら止まる。
    private func launch(lossInterval: String? = nil, lossMax: String = "1", kind: String? = nil) {
        if let lossInterval {
            app.launchArguments += ["-claude.hwLossInterval", lossInterval, "-claude.hwLossMax", lossMax]
        }
        if let kind {
            app.launchArguments += ["-claude.hwLossKind", kind]
            // CI のシミュレータはソフトウェアキーボードが出ない(付属バーだけ)ので、出ているものとして扱わせる
            if kind == "user" { app.launchArguments += ["--claude-soft-keyboard"] }
        }
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "入力欄が見つからない")
    }

    private var composer: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "claude.composer").firstMatch
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func hasFocus() -> Bool {
        (composer.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func restoredCount() -> Int {
        let label = element("claude.debug.guard").label
        guard let r = label.range(of: "restored=") else { return -1 }
        return Int(label[r.upperBound...].prefix { $0.isNumber }) ?? -1
    }

    private func focusComposer() {
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // キーボードが出た直後は hasKeyboardFocus がまだ false のことがあるので、付くまで少し待つ
        XCTAssertTrue(waitUntil(5) { hasFocus() }, "タップしてもフォーカスが付かない [\(element("claude.debug.guard").label)]")
    }

    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return cond()
    }

    /// システムにフォーカスを奪われても、すぐ入力欄に戻り、打ち続けられて、打った文字も残る
    func testFocusIsRestoredAfterSystemLoss() throws {
        launch(lossInterval: "6", lossMax: "1")
        focusComposer()
        composer.typeText("keep me")
        XCTAssertTrue(waitUntil(20) { restoredCount() == 1 && hasFocus() },
                      "奪われた後に戻らない [\(element("claude.debug.guard").label)]")
        composer.typeText(" ok")
        XCTAssertEqual(composer.value as? String, "keep me ok", "戻った後に打った文字がつながらない")
    }

    /// 何度も奪われても、戻すのは 5 秒に 3 回まで(暴れない)。本人が触ればまた戻すようになる
    func testRestoreHasALimitAndUserTouchResetsIt() throws {
        launch(lossInterval: "0.7", lossMax: "20")
        // 奪うタイマが動いているので、フォーカスの確認は競合する(確認の間に奪われる)。戻した回数だけを見る
        composer.tap()
        XCTAssertTrue(waitUntil(20) { restoredCount() >= 3 }, "戻していない [\(element("claude.debug.guard").label)]")
        // 4 回目以降は戻さない(5 秒に 3 回の上限)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(restoredCount(), 3, "上限を超えて戻している(暴れる) [\(element("claude.debug.guard").label)]")
        // 本人が触れば、また戻すようになる
        composer.tap()
        XCTAssertTrue(waitUntil(20) { restoredCount() > 3 }, "本人が触っても再開しない [\(element("claude.debug.guard").label)]")
    }

    /// 本人がキーボードを閉じたもの(ソフトウェアキーボードが出ている間の、システム要因でない喪失)は戻さない
    func testKeyboardClosedByUserIsNotPushedBack() throws {
        launch(lossInterval: "4", lossMax: "1", kind: "user")
        // 奪うタイマが動いているので、タップ直後のフォーカスの確認は競合する(確認の前に外れる)。外れたことは札で見る
        composer.tap()
        XCTAssertTrue(waitUntil(20) { element("claude.debug.guard").label.contains("user-dismiss") },
                      "本人が閉じたものと判定されない [\(element("claude.debug.guard").label)]")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(restoredCount(), 0, "閉じたのに戻された [\(element("claude.debug.guard").label)]")
        XCTAssertFalse(hasFocus(), "閉じたのにフォーカスが付いている")
        // 本人が欄を触れば、また使える
        composer.tap()
        XCTAssertTrue(waitUntil(5) { hasFocus() })
    }

    /// 履歴をスクロールしても、キーボードもフォーカスも外れない
    func testScrollingTimelineKeepsKeyboardWhileHardwareAttached() throws {
        launch()
        focusComposer()
        composer.typeText("hello")
        let timeline = element("claude.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        timeline.swipeDown()
        timeline.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(hasFocus(), "スクロールでフォーカスが外れた")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(restoredCount(), 0, "スクロールで外れて戻した(外れ自体を止めるべき) [\(element("claude.debug.guard").label)]")
    }
}
