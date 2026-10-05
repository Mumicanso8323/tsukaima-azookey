//
//  ClaudeScrollUITests.swift
//  本人の声(2026-10-05):「IME を開いたら上までスクロールしたり、逆に意図しないタイミングで下までスクロールしたり」。
//  入力欄の高さが変わる(キーボードが出る・変換の候補バーが出る・行が増える)ときに、一覧が勝手に跳ばないことを確かめる。
//  位置は見えない札 claude.debug.scroll(ClaudeScrollProbe)で読む: top=上端からの距離 bottom=下端までの距離
//  jumpTop / jumpBottom = 本人がスクロールしていないのに一番上・一番下へ跳んだ回数。
//
//  限界: 変換の候補バーはシミュレータで出せないので、入力欄が複数行に伸びることで「入力欄の高さの変化」を作る。
//

import XCTest

final class ClaudeScrollUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["--claude-mock", "--claude-mock-long"] + extra
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(10) { self.probe().top > 0 }, "一覧の位置が読めない [\(self.probeLabel)]")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    private var composer: XCUIElement { element("claude.composer") }
    private var timeline: XCUIElement { element("claude.timeline") }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var probeLabel: String { element("claude.debug.scroll").label }

    private func probe() -> (top: Int, bottom: Int, jumpTop: Int, jumpBottom: Int) {
        let label = probeLabel
        func num(_ key: String) -> Int {
            guard let r = label.range(of: key + "=") else { return -9999 }
            let rest = label[r.upperBound...]
            let digits = rest.prefix { $0 == "-" || $0.isNumber }
            return Int(digits) ?? -9999
        }
        return (num("top"), num("bottom"), num("jumpTop"), num("jumpBottom"))
    }

    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return cond()
    }

    /// 入力欄が 4〜5 行に伸びる長さ(Enter は送信になるので使わない)
    private let longText = String(repeating: "scroll check words ", count: 10)

    /// 最下部を見ている時に入力欄を開いて打ち、入力欄が伸びても、最下部のまま・一番上へ跳ばない
    func testOpeningKeyboardAndGrowingComposerKeepsBottom() throws {
        launch()
        XCTAssertLessThanOrEqual(probe().bottom, 80, "起動後に最下部にいない [\(probeLabel)]")
        composer.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertLessThanOrEqual(probe().bottom, 80, "キーボードを開いたら最下部から外れた [\(probeLabel)]")
        composer.typeText(longText)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let p = probe()
        XCTAssertEqual(p.jumpTop, 0, "一番上へ跳んだ [\(probeLabel)]")
        XCTAssertGreaterThan(p.top, 600, "上のほうへ動いた [\(probeLabel)]")
        XCTAssertLessThanOrEqual(p.bottom, 80, "入力欄が伸びたら最下部の行が隠れた [\(probeLabel)]")
    }

    /// 上を読んでいる時に入力欄を開いて打っても、一番下へも一番上へも跳ばない
    func testReadingUpThenTypingDoesNotJump() throws {
        launch()
        timeline.swipeDown(velocity: .fast)
        timeline.swipeDown(velocity: .fast)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let before = probe()
        XCTAssertGreaterThan(before.bottom, 400, "上へ戻れていない [\(probeLabel)]")
        composer.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        composer.typeText(longText)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let p = probe()
        XCTAssertEqual(p.jumpTop, 0, "一番上へ跳んだ [\(probeLabel)]")
        XCTAssertEqual(p.jumpBottom, 0, "読んでいる途中で一番下へ跳んだ [\(probeLabel)]")
        XCTAssertGreaterThan(p.bottom, 300, "読んでいた位置から最下部へ引き戻された [\(probeLabel)]")
    }

    /// 上を読んでいる間に新着が流れても、キーボードを出し入れしても、跳ばない
    func testReadingUpWhileStreamingAndKeyboardDoesNotJump() throws {
        launch(["--claude-mock-stream"])
        timeline.swipeDown(velocity: .fast)
        timeline.swipeDown(velocity: .fast)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        composer.tap()
        composer.typeText("hello")
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        let p = probe()
        XCTAssertEqual(p.jumpTop, 0, "一番上へ跳んだ [\(probeLabel)]")
        XCTAssertEqual(p.jumpBottom, 0, "読んでいる途中で一番下へ跳んだ [\(probeLabel)]")
        XCTAssertGreaterThan(p.bottom, 300, "新着で最下部へ引き戻された [\(probeLabel)]")
    }
}
