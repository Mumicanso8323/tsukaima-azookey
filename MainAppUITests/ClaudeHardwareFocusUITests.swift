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
        XCTAssertTrue(hasFocus(), "タップしてもフォーカスが付かない")
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
        focusComposer()
        composer.typeText("keep me")
        XCTAssertEqual(restoredCount(), 0)
        let loss = element("claude.debug.forceLoss")
        XCTAssertTrue(loss.waitForExistence(timeout: 5), "テスト用の「奪う」ボタンが無い")
        loss.tap()
        XCTAssertTrue(waitUntil(5) { restoredCount() == 1 && hasFocus() }, "奪われた後に戻らない [\(element("claude.debug.guard").label)]")
        composer.typeText(" ok")
        XCTAssertEqual(composer.value as? String, "keep me ok", "戻った後に打った文字がつながらない")
    }

    /// 何度も奪われても戻すのは回数に上限があり(暴れない)、本人が触ればまた使える
    func testRestoreHasALimitAndUserTouchResetsIt() throws {
        focusComposer()
        let loss = element("claude.debug.forceLoss")
        XCTAssertTrue(loss.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            loss.tap()
            _ = waitUntil(3) { hasFocus() }
        }
        XCTAssertLessThanOrEqual(restoredCount(), 3)
        // 4 回目は戻さない(5 秒の間に 3 回戻したので止まる)
        loss.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(hasFocus(), "上限を超えても戻し続けている(暴れる) [\(element("claude.debug.guard").label)]")
        XCTAssertEqual(restoredCount(), 3)
        // 本人が触れば使える
        composer.tap()
        XCTAssertTrue(waitUntil(5) { hasFocus() })
    }

    /// 履歴をスクロールしても、キーボードもフォーカスも外れない
    func testScrollingTimelineKeepsKeyboardWhileHardwareAttached() throws {
        focusComposer()
        composer.typeText("hello")
        let timeline = element("claude.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        timeline.swipeDown()
        timeline.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(hasFocus(), "スクロールでフォーカスが外れた")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(restoredCount(), 0, "スクロールで外れて戻した(外れ自体を止めるべき)")
    }
}
