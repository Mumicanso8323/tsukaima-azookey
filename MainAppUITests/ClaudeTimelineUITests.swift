//
//  ClaudeTimelineUITests.swift
//  Claude タブの表示(公式アプリ並みの見せ方)をシミュレータで確かめる。アプリは `--claude-mock`(ClaudeMockDriver)。
//  固定の履歴: 添付画像つきの発言 → Bash・Read・Edit・Write(report.html)→ Markdown の返事(見出し・太字・
//  箇条書き・コードブロック・表・引用のリンク・パスのリンク)。
//

import XCTest

final class ClaudeTimelineUITests: XCTestCase {
    private var app: XCUIApplication!

    /// 失敗の手がかり: 終わるときの「編集の回数」と「メインスレッドの最大の詰まり」を記録する
    override func tearDown() {
        let tag = app.descendants(matching: .any).matching(identifier: "claude.debug.focus").firstMatch
        if app.state == .runningForeground, tag.exists { print("PROBE: timeline \(tag.label)") }
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--claude-mock"]
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(element("claude.composer").waitForExistence(timeout: 20), "入力欄が見つからない")
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func elements(_ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    private func closeSheet() {
        let done = element("claude.sheet.done")
        XCTAssertTrue(done.waitForExistence(timeout: 5), "シートの「完了」が無い")
        done.tap()
    }

    // MARK: ツールのログ

    /// Bash などのツールは 1 行に畳まれ、生の出力は既定で出ない。タップで一覧、さらにタップで出力。
    func testToolCallsAreFoldedIntoOneLine() throws {
        launch()
        let activity = element("claude.activity")
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        XCTAssertEqual(elements("claude.activity").count, 1, "連続したツール呼び出しは 1 つのまとまり")
        XCTAssertTrue(activity.label.contains("コマンド 1") && activity.label.contains("読む 1") && activity.label.contains("編集 1"),
                      "まとまりの見出し: \(activity.label)")
        XCTAssertFalse(app.staticTexts["total 8\n-rw-r--r-- README.md"].exists, "生の出力が既定で出ている")
        XCTAssertEqual(elements("claude.toolCall").count, 0, "開く前から中の一覧が出ている")

        activity.tap()
        XCTAssertTrue(element("claude.toolCall").waitForExistence(timeout: 5))
        XCTAssertEqual(elements("claude.toolCall").count, 4, "Bash・Read・Edit・Write の 4 行")
        XCTAssertFalse(app.staticTexts["total 8\n-rw-r--r-- README.md"].exists, "一覧を開いただけで出力が出ている")
        elements("claude.toolCall").element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["total 8\n-rw-r--r-- README.md"].waitForExistence(timeout: 5), "呼び出しを開いても出力が見えない")
    }

    // MARK: Markdown

    func testMarkdownIsRendered() throws {
        launch()
        XCTAssertTrue(app.staticTexts["直しました"].waitForExistence(timeout: 10), "見出しが Markdown として出ていない")
        XCTAssertFalse(app.staticTexts["## 直しました"].exists, "見出しの記号が生で出ている")
        XCTAssertTrue(app.staticTexts["git diff README.md"].exists, "コードブロックの本文が無い")
        let copy = element("claude.md.copyCode")
        XCTAssertTrue(copy.exists, "コードブロックのコピーボタンが無い")
        XCTAssertTrue(app.staticTexts["見出し"].exists && app.staticTexts["済"].exists, "表のセルが無い")
        XCTAssertFalse(app.staticTexts["| 項目 | 状態 |"].exists, "表が生で出ている")
        copy.tap()
        // ボタンの中の文字はボタンの名前に吸収されるので、ボタンの名前が変わるのを待つ(2 秒で元に戻る)
        XCTAssertTrue(app.buttons["コピーしました"].waitForExistence(timeout: 1.8), "コピーしたことが分からない")
    }

    func testCopyWholeMessage() throws {
        launch()
        let copy = element("claude.copyMessage")
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertTrue(app.buttons["コピーしました"].waitForExistence(timeout: 3), "返事のコピーの手応えが無い")
    }

    func testSelectTextSheetFromLongPress() throws {
        launch()
        let bubble = app.staticTexts["README の見出しを整えて"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "添付は本文から外れて、本文だけが吹き出しに出る")
        bubble.press(forDuration: 1.0)
        let select = app.buttons["テキストを選択"]
        XCTAssertTrue(select.waitForExistence(timeout: 5), "長押しのメニューに「テキストを選択」が無い")
        XCTAssertTrue(app.buttons["コピー"].exists)
        XCTAssertTrue(app.buttons["もう一度送る"].exists)
        select.tap()
        XCTAssertTrue(element("claude.selectText").waitForExistence(timeout: 5))
        closeSheet()
    }

    // MARK: リンク・成果物・ファイル・画像

    func testLinkOpensInAppBrowser() throws {
        launch()
        let link = app.links["GitHub"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "本文のリンクが押せる形になっていない")
        link.tap()
        // SFSafariViewController の中身は別プロセスなので、外枠の識別子か標準の「完了/Done」ボタンで判定する
        let opened = element("claude.browser").waitForExistence(timeout: 10)
            || app.buttons["Done"].waitForExistence(timeout: 3) || app.buttons["完了"].exists
        XCTAssertTrue(opened, "リンクがアプリ内ブラウザで開かない")
    }

    func testPathInTextOpensFileViewer() throws {
        launch()
        let link = app.links["/data/ashwell/mock/notes.md"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "本文中のパスがリンクになっていない")
        link.tap()
        XCTAssertTrue(element("claude.fileViewer").waitForExistence(timeout: 10), "パスがファイル閲覧で開かない")
        closeSheet()
    }

    func testArtifactCardOpensHTMLViewer() throws {
        launch()
        let card = element("claude.artifact")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Write した report.html のカードが無い")
        card.tap()
        XCTAssertTrue(element("claude.fileViewer").waitForExistence(timeout: 10))
        XCTAssertTrue(element("claude.fileViewer.html").waitForExistence(timeout: 10), "HTML が WebView で開かない")
        XCTAssertTrue(app.webViews.staticTexts["表示できています"].waitForExistence(timeout: 10), "HTML の中身が描かれていない")
        closeSheet()
    }

    func testAttachedImageThumbnailOpensZoomableViewer() throws {
        launch()
        let thumb = element("claude.attachment.image")
        XCTAssertTrue(thumb.waitForExistence(timeout: 10), "添付画像の縮小表示が無い")
        thumb.tap()
        XCTAssertTrue(element("claude.imageViewer").waitForExistence(timeout: 10), "画像の全画面表示が開かない")
        closeSheet()
    }

    /// ファイル一覧のボタンは、一覧の画面テストが通るまでこの版では出さない。出ていないこと、本文のパスからの閲覧は生きていること。
    func testFileBrowserButtonIsHiddenInThisVersion() throws {
        launch()
        XCTAssertTrue(element("claude.more").waitForExistence(timeout: 10), "上のバーが出ていない")
        XCTAssertFalse(element("claude.openFiles").exists, "ファイル一覧のボタンが出ている(この版では隠す)")
        XCTAssertTrue(app.links["/data/ashwell/mock/notes.md"].exists, "本文のパスからの閲覧は残す")
    }

    // MARK: 生成中・止める・送る

    func testStopButtonWhileWorking() throws {
        launch()
        let composer = element("claude.composer")
        composer.tap()
        composer.typeText("作業して")
        element("claude.send").tap()
        // 偽サーバーは送信を受けると作業中になる。文字が空なら送信ボタンが「止める」に変わる
        let stop = element("claude.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "作業中に止めるボタンが出ない")
        XCTAssertTrue(element("claude.working").exists, "作業中の表示が無い")
        // 文字を打つと送信ボタンに戻る(作業中でも追加で送れる)
        composer.typeText("a")
        XCTAssertTrue(element("claude.send").waitForExistence(timeout: 3))
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        stop.tap()
        XCTAssertTrue(element("claude.send").waitForExistence(timeout: 5), "止めたのに作業中のまま")
        XCTAssertFalse(element("claude.working").exists)
    }

    // MARK: スクロール

    /// 上を読んでいる間は新着が来ても下へ飛ばない。「↓」で最下部へ戻れる。
    func testScrollingUpIsNotYankedToBottom() throws {
        launch(["--claude-mock-stream", "--claude-mock-long"])
        let timeline = app.scrollViews["claude.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        timeline.swipeDown(velocity: .fast)
        timeline.swipeDown(velocity: .fast)
        let toBottom = element("claude.scrollToBottom")
        XCTAssertTrue(toBottom.waitForExistence(timeout: 5), "上へ戻っても「最新へ」ボタンが出ない")
        Thread.sleep(forTimeInterval: 4)   // この間も新着が流れ続ける
        XCTAssertTrue(toBottom.exists, "上を読んでいる間に下へ引き戻された")
        toBottom.tap()
        XCTAssertTrue(toBottom.waitForNonExistence(timeout: 5), "「最新へ」で最下部へ戻らない")
    }

    /// 長い会話(約 2400 件)+ 更新が流れている中でも、打鍵がもたつかない
    func testLongConversationStaysResponsive() throws {
        let start = Date()
        launch(["--claude-mock-stream", "--claude-mock-long"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 25, "長い会話の起動が遅い")
        let composer = element("claude.composer")
        composer.tap()
        let t0 = Date()
        composer.typeText("responsive typing check 123")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15, "長い会話で打鍵が遅い")
        XCTAssertEqual(composer.value as? String, "responsive typing check 123")
    }
}
