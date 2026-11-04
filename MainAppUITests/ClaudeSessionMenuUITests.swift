//
//  ClaudeSessionMenuUITests.swift
//  Claude タブのセッションメニューに「声の送り先」が出ないことを確かめる(送り先は hub がメインの使い魔に固定)。
//  アプリは `--claude-mock`(ClaudeMockDriver)。
//

import XCTest

final class ClaudeSessionMenuUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--claude-mock"]
        app.launch()
    }

    private func anyElement(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testSessionMenuHasNoVoiceDestination() throws {
        let menu = app.descendants(matching: .any).matching(identifier: "claude.sessionMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "セッションメニューが見つからない")
        menu.tap()
        // 行(モックの「作業1」)が出る=メニューが開いている
        let row = anyElement(containing: "作業1")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "セッションの行が出ない")
        XCTAssertFalse(anyElement(containing: "声の送り先").exists, "メニュー直下に声の送り先が出ている")
        row.tap()
        XCTAssertTrue(app.buttons["このセッションを見る"].waitForExistence(timeout: 10), "行のメニューが開かない")
        XCTAssertFalse(anyElement(containing: "声の送り先").exists, "行のメニューに声の送り先が出ている")
    }
}
