import XCTest

/// 薙刀式のメモ帳・練習画面。XCUITest は物理キーを送れないので、--naginata-mock-keys で
/// 時刻つきの打鍵列を、実機と同じエンジン・出力経路へ流す。物理キーボード(UIPress の時刻)の経路は未検証。
final class NaginataPracticeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--naginata-mock-keys", "--naginata-reset"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func wait(_ timeout: TimeInterval = 8, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    private func openNotepad() {
        let entry = app.buttons["薙刀式のメモ帳"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        entry.tap()
        XCTAssertTrue(element("naginata.editor").waitForExistence(timeout: 10))
    }

    private func openPractice() {
        let entry = app.buttons["薙刀式の練習"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        entry.tap()
        XCTAssertTrue(element("naginata.practice.editor").waitForExistence(timeout: 10))
    }

    private func editorText(_ id: String = "naginata.editor") -> String {
        (element(id).value as? String) ?? ""
    }

    // MARK: メモ帳

    func testSingleStrokeShowsKana() {
        openNotepad()
        element("naginata.mock.single").tap()
        XCTAssertTrue(wait { editorText().contains("きてあ") }, "単打 w e j → きてあ。実際: \(editorText())")
    }

    func testSimultaneousShowsVoiced() {
        openNotepad()
        element("naginata.mock.simul").tap()
        XCTAssertTrue(wait { editorText().contains("ざぎ") }, "F+U→ざ, J+W→ぎ。実際: \(editorText())")
    }

    func testSymbolsShow() {
        openNotepad()
        element("naginata.mock.symbols").tap()
        XCTAssertTrue(wait { editorText().contains("？「」") }, "J+K+D/F/V → ？「」。実際: \(editorText())")
    }

    func testLayoutFigureExists() {
        openNotepad()
        XCTAssertTrue(element("naginata.layout").exists)
        XCTAssertTrue(element("naginata.key.w").exists)
        XCTAssertTrue(element("naginata.key.space").exists)
    }

    // MARK: 複数メモ

    func testNotesNewListSwitchDelete() {
        openNotepad()
        element("naginata.mock.single").tap()
        XCTAssertTrue(wait { editorText().contains("きてあ") })

        // 新規 → 空のメモ
        element("naginata.notes.new").tap()
        XCTAssertTrue(wait { !editorText().contains("きてあ") }, "新規は空のメモ")
        element("naginata.mock.simul").tap()
        XCTAssertTrue(wait { editorText().contains("ざぎ") })

        // 一覧: 2 枚ある。1 枚目に切り替える
        element("naginata.notes.list").tap()
        XCTAssertTrue(element("naginata.notes.row.1").waitForExistence(timeout: 10))
        XCTAssertTrue(element("naginata.notes.row.2").exists)
        element("naginata.notes.row.1").tap()
        XCTAssertTrue(wait { editorText().contains("きてあ") }, "1 枚目に戻る。実際: \(editorText())")

        // 一覧からスワイプで 2 枚目を削除
        element("naginata.notes.list").tap()
        XCTAssertTrue(element("naginata.notes.row.2").waitForExistence(timeout: 10))
        element("naginata.notes.row.2").swipeLeft()
        let delete = app.buttons["Delete"].exists ? app.buttons["Delete"] : app.buttons["削除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(wait { !self.element("naginata.notes.row.2").exists }, "2 枚目が消える")
        XCTAssertTrue(element("naginata.notes.row.1").exists)
    }

    // MARK: 練習画面

    func testPracticeHighlightsAndProgresses() {
        openPractice()
        XCTAssertTrue(element("naginata.layout").waitForExistence(timeout: 5))
        // 1 文字目「い」は K の単打
        XCTAssertTrue(wait { (self.element("naginata.key.k").value as? String) == "base" }, "次のキー K が光る")
        XCTAssertEqual(element("naginata.key.w").value as? String, "off")

        // 「いいね。」を 1 まとまりずつ打つ。3 まとまり目「ね」は Space(修飾)+W(主)
        element("naginata.mock.nexttoken").tap()
        element("naginata.mock.nexttoken").tap()
        XCTAssertTrue(wait { (self.element("naginata.key.w").value as? String) == "base" }, "次は ね: W が主")
        XCTAssertEqual(element("naginata.key.space").value as? String, "modifier")

        element("naginata.mock.nexttoken").tap()
        element("naginata.mock.nexttoken").tap()
        XCTAssertTrue(element("naginata.practice.done").waitForExistence(timeout: 10), "打ち終えた表示")
    }
}
