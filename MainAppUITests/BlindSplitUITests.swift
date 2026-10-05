import XCTest

/// ブラインドの返事の専用経路(docs/blind-decouple.md 段階 2)。--blind-mock-replies は本物のサーバー・音・振動に触れず、
/// 同じ受信経路へ偽の返事を流し、振動・音声開始・合図音プレーヤー作成の回数を画面の数字で見せる。
final class BlindSplitUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--claude-mock", "--blind-mock-replies"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openBlind(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.tabBars.buttons["使い魔"].waitForExistence(timeout: 20), file: file, line: line)
        app.tabBars.buttons["使い魔"].tap()
        XCTAssertTrue(app.buttons["ブラインド"].waitForExistence(timeout: 10), file: file, line: line)
        app.buttons["ブラインド"].tap()
        XCTAssertTrue(element("blind.status").waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(element("blind.debug.host").waitForExistence(timeout: 10), file: file, line: line)
    }

    /// 条件が満たされるまで最大 timeout 秒待つ。
    private func wait(_ timeout: TimeInterval = 8, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    private func isSelected(_ mode: String) -> Bool {
        (element("blind.output.\(mode)").value as? String) == "selected"
    }

    private func hapticsCount() -> Int {
        let label = element("blind.debug.haptics").label
        return Int(label.split(separator: "|", omittingEmptySubsequences: false).first ?? "") ?? -1
    }

    private func replyText() -> String { element("blind.reply.text").label }

    // MARK: 出し方のチップ

    func testOutputChipsSwitch() {
        openBlind()
        XCTAssertTrue(element("blind.output.voice").waitForExistence(timeout: 5))
        XCTAssertTrue(wait { isSelected("voice") }, "既定は voice")
        XCTAssertFalse(isSelected("text"))

        element("blind.output.text").tap()
        XCTAssertTrue(wait { isSelected("text") })
        XCTAssertFalse(isSelected("voice"))

        element("blind.output.both").tap()
        XCTAssertTrue(wait { isSelected("both") })
        XCTAssertFalse(isSelected("text"))

        element("blind.output.voice").tap()
        XCTAssertTrue(wait { isSelected("voice") })
    }

    // MARK: TEXT の返事

    func testTextModeReplyShowsCardAndVibratesWithoutAudio() {
        openBlind()
        element("blind.output.text").tap()
        XCTAssertTrue(wait { isSelected("text") })
        XCTAssertEqual(hapticsCount(), 0)

        element("blind.mock.reply").tap()
        XCTAssertTrue(element("blind.reply.card").waitForExistence(timeout: 5))
        XCTAssertTrue(wait { replyText().contains("モックの返事 1") }, "カードに返事が出ない: \(replyText())")
        XCTAssertTrue(wait { hapticsCount() == 1 }, "振動が 1 回: \(element("blind.debug.haptics").label)")
        XCTAssertTrue(element("blind.debug.haptics").label.contains("reply"))
        XCTAssertEqual(element("blind.debug.audioStarts").label, "0", "TEXT では音声を始めない")
        XCTAssertEqual(element("blind.debug.tones").label, "0", "TEXT では合図音のプレーヤーを作らない")
    }

    func testDuplicateReplyDoesNotVibrateTwice() {
        openBlind()
        element("blind.output.text").tap()
        XCTAssertTrue(wait { isSelected("text") })
        element("blind.mock.reply").tap()
        XCTAssertTrue(wait { hapticsCount() == 1 })
        element("blind.mock.reply.dup").tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(hapticsCount(), 1, "同じ rid は 1 回だけ処理する")
        XCTAssertTrue(replyText().contains("モックの返事 1"))
    }

    func testReadDeniedBuzzes() {
        openBlind()
        element("blind.output.text").tap()
        XCTAssertTrue(wait { isSelected("text") })
        element("blind.mock.read_denied").tap()
        XCTAssertTrue(wait { hapticsCount() == 1 })
        XCTAssertTrue(element("blind.debug.haptics").label.contains("cannotRead"))
        XCTAssertEqual(element("blind.debug.audioStarts").label, "0")
    }

    func testServerOutputChangeToTextBuzzesWithoutSound() {
        openBlind()
        element("blind.mock.output.text").tap()
        XCTAssertTrue(wait { isSelected("text") }, "サーバー(キー)での切り替えがチップに出る")
        XCTAssertTrue(wait { hapticsCount() == 1 })
        XCTAssertTrue(element("blind.debug.haptics").label.contains("modeText"))
        XCTAssertEqual(element("blind.debug.tones").label, "0", "TEXT に入る瞬間は音を鳴らさない")
    }

    // MARK: 長い返事

    func testLongReplyOpensFullTextSheetAndShortReplyDoesNot() {
        openBlind()
        element("blind.mock.reply.long").tap()
        XCTAssertTrue(wait { replyText().contains("…(全 300 字)") }, "切り詰めの注記が出ない: \(replyText())")
        XCTAssertTrue(element("blind.reply.more").waitForExistence(timeout: 5))
        element("blind.reply.more").tap()
        XCTAssertTrue(element("blind.reply.full").waitForExistence(timeout: 5), "全文のシートが開かない")
        XCTAssertEqual(element("blind.reply.full").label.count, 300)
        XCTAssertTrue(element("blind.reply.full.close").waitForExistence(timeout: 5))
        element("blind.reply.full.close").tap()
        XCTAssertTrue(wait { !element("blind.reply.full").exists })
        XCTAssertTrue(element("blind.status").exists, "シートを閉じてもブラインド画面が残る")

        element("blind.mock.reply").tap()
        XCTAssertTrue(wait { replyText().contains("モックの返事 2") || replyText().contains("モックの返事") })
        XCTAssertTrue(wait { !element("blind.reply.more").exists }, "短い返事に全文ボタンは出ない")
    }

    // MARK: タブをまたいでも接続が続く

    func testLinkStaysAliveWhileClaudeTabIsFrontmost() {
        openBlind()
        element("blind.output.text").tap()
        XCTAssertTrue(wait { isSelected("text") })
        XCTAssertTrue(element("blind.debug.host").label.contains("enabled=1"))
        XCTAssertTrue(element("blind.debug.host").label.contains("connects=1"))

        element("blind.mock.reply.delayed").tap()
        XCTAssertTrue(app.tabBars.buttons["Claude"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Claude"].tap()
        Thread.sleep(forTimeInterval: 6)  // Claude タブが前面のまま、画面に結び付かない遅延の返事が届く

        app.tabBars.buttons["使い魔"].tap()
        if !element("blind.reply.card").waitForExistence(timeout: 3) {
            XCTAssertTrue(app.buttons["ブラインド"].waitForExistence(timeout: 5))
            app.buttons["ブラインド"].tap()
        }
        XCTAssertTrue(element("blind.debug.host").waitForExistence(timeout: 10))
        XCTAssertTrue(wait(10) { replyText().contains("遅れて届いた返事") }, "Claude タブ中に届いた返事が出ない: \(replyText())")
        XCTAssertEqual(hapticsCount(), 0, "Claude タブが前面でアプリが active のときは振動しない")
        let host = element("blind.debug.host").label
        XCTAssertTrue(host.contains("enabled=1"), host)
        XCTAssertTrue(host.contains("connects=1"), "画面の出入りでつなぎ直していない: \(host)")
    }

    func testOpenInClaudeTabSwitchesTab() {
        openBlind()
        XCTAssertTrue(element("blind.reply.openClaude").waitForExistence(timeout: 5))
        element("blind.reply.openClaude").tap()
        XCTAssertTrue(wait { self.app.tabBars.buttons["Claude"].isSelected }, "Claude タブに切り替わらない")
    }
}
