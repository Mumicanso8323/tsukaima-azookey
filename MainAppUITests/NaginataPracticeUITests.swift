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

    // MARK: 練習画面(縦画面の左右の配列図・タップなしで続ける)

    private func label(_ id: String) -> String {
        element(id).label
    }

    func testPracticeSplitKeyboardInPortrait() {
        XCUIDevice.shared.orientation = .portrait
        openPractice()
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.height, window.width, "縦画面")

        let left = element("naginata.layout.left")
        let right = element("naginata.layout.right")
        XCTAssertTrue(left.waitForExistence(timeout: 5), "左手の配列図")
        XCTAssertTrue(right.exists, "右手の配列図")
        // 左手が上、右手が下(上下 2 段)
        XCTAssertLessThanOrEqual(left.frame.maxY, right.frame.minY + 1, "左手 \(left.frame) が右手 \(right.frame) の上")

        // 左手は Q〜B、右手は Y〜/ の 5 列 × 3 段。それぞれの枠の中にある
        for k in Array("qwertasdfgzxcvb") {
            let key = element("naginata.key.\(k)")
            XCTAssertTrue(key.exists, "左手のキー \(k)")
            XCTAssertTrue(left.frame.insetBy(dx: -1, dy: -1).contains(key.frame), "\(k) は左手 \(key.frame)")
        }
        for k in Array("yuiophjkl;nm,./") {
            let key = element("naginata.key.\(k)")
            XCTAssertTrue(key.exists, "右手のキー \(k)")
            XCTAssertTrue(right.frame.insetBy(dx: -1, dy: -1).contains(key.frame), "\(k) は右手 \(key.frame)")
        }
        XCTAssertTrue(element("naginata.key.space").exists)

        // キーが大きい(1 段 5 キーで画面幅を使う。縦画面の iPhone で幅 60pt 前後・高さ 60pt)
        for k in Array("qtyp") {
            let f = element("naginata.key.\(k)").frame
            XCTAssertGreaterThanOrEqual(f.width, window.width / 7, "\(k) の幅 \(f.width)(画面 \(window.width))")
            XCTAssertGreaterThanOrEqual(f.height, 56, "\(k) の高さ \(f.height)")
            XCTAssertGreaterThanOrEqual(f.minX, window.minX - 0.5, "\(k) が左にはみ出さない")
            XCTAssertLessThanOrEqual(f.maxX, window.maxX + 0.5, "\(k) が右にはみ出さない")
        }
        // 光るキーは分けた図でも同じ(1 文字目「い」は K)
        XCTAssertTrue(wait { (self.element("naginata.key.k").value as? String) == "base" }, "次のキー K が光る")
    }

    func testPracticeStartsFocusedAndAdvancesWithoutTap() {
        openPractice()
        // 入力欄に触らなくてもフォーカスが入っている
        XCTAssertTrue(wait { self.label("naginata.practice.focus") == "focused" }, "開いただけでフォーカス。実際: \(label("naginata.practice.focus"))")
        XCTAssertTrue(label("naginata.practice.counter").hasPrefix("1 /"))
        XCTAssertEqual(label("naginata.practice.target"), "いいね。")

        // 「いいね。」を打つ(打鍵のみ。次へ のボタンは押さない)
        for _ in 0 ..< 4 { element("naginata.mock.nexttoken").tap() }
        XCTAssertTrue(wait { self.label("naginata.practice.counter").hasPrefix("2 /") }, "打ち終えたら自動で次のお題へ。実際: \(label("naginata.practice.counter"))")
        XCTAssertTrue(wait { self.label("naginata.practice.target") == "ありがとう。" }, "実際: \(label("naginata.practice.target"))")
        XCTAssertTrue(element("naginata.practice.done").exists, "前のお題の結果が残る")
        XCTAssertTrue(element("naginata.practice.result").exists, "速さ・間違い")
        XCTAssertTrue(wait { self.editorText("naginata.practice.editor").isEmpty }, "入力欄は空に戻る。実際: \(editorText("naginata.practice.editor"))")
        XCTAssertEqual(label("naginata.practice.focus"), "focused", "次のお題でもフォーカスは外れない")

        // 続けて 2 問目も打鍵だけで打ち終えて 3 問目へ
        for _ in 0 ..< 12 {
            if label("naginata.practice.counter").hasPrefix("3 /") { break }
            element("naginata.mock.nexttoken").tap()
        }
        XCTAssertTrue(wait { self.label("naginata.practice.counter").hasPrefix("3 /") }, "2 問目も自動で次へ。実際: \(label("naginata.practice.counter"))")
        XCTAssertEqual(label("naginata.practice.focus"), "focused")
    }

    func testPracticeKeysRetrySkipEnter() {
        openPractice()
        XCTAssertTrue(wait { self.label("naginata.practice.focus") == "focused" })
        element("naginata.mock.nexttoken").tap()
        XCTAssertTrue(wait { self.editorText("naginata.practice.editor").contains("い") }, "1 文字打った。実際: \(editorText("naginata.practice.editor"))")

        // Esc: やり直し(同じお題を最初から)
        element("naginata.mock.esc").tap()
        XCTAssertTrue(wait { self.editorText("naginata.practice.editor").isEmpty }, "Esc で空に。実際: \(editorText("naginata.practice.editor"))")
        XCTAssertTrue(label("naginata.practice.counter").hasPrefix("1 /"))
        XCTAssertEqual(label("naginata.practice.target"), "いいね。")

        // Tab: 飛ばして次へ
        element("naginata.mock.tab").tap()
        XCTAssertTrue(wait { self.label("naginata.practice.counter").hasPrefix("2 /") }, "Tab で次へ。実際: \(label("naginata.practice.counter"))")

        // Enter: 改行は入らず、お題もそのまま
        element("naginata.mock.enter").tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(editorText("naginata.practice.editor").isEmpty, "Enter で改行が入らない。実際: \(editorText("naginata.practice.editor").debugDescription)")
        XCTAssertTrue(label("naginata.practice.counter").hasPrefix("2 /"))
        XCTAssertEqual(label("naginata.practice.focus"), "focused")
    }
}
