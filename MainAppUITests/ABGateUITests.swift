//
//  ABGateUITests.swift
//  起動直後に出るノアの絵柄の A/B(ABGateView)を、偽サーバー(`--ab-mock`、3 組)で確かめる。
//

import XCTest

final class ABGateUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ab-mock"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var progress: XCUIElement { app.staticTexts["ab.progress"] }

    private func waitForProgress(_ text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@", text)
        let exp = expectation(for: predicate, evaluatedWith: progress)
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed, "progress が \(text) にならない(いま: \(progress.label))", file: file, line: line)
    }

    func testGateAppearsAtLaunch() {
        XCTAssertTrue(element("ab.screen").waitForExistence(timeout: 20))
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        waitForProgress("1/3")
        XCTAssertTrue(element("ab.imageA").exists)
        XCTAssertTrue(element("ab.imageB").exists)
    }

    func testVoteThroughAllPairsThenNormalUI() {
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        waitForProgress("1/3")
        app.buttons["ab.choiceA"].tap()
        waitForProgress("2/3")
        app.buttons["ab.choiceB"].tap()
        waitForProgress("3/3")
        app.buttons["ab.choiceNone"].tap()
        let gone = NSPredicate(format: "exists == false")
        let exp = expectation(for: gone, evaluatedWith: element("ab.screen"))
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: 10), .completed, "最後の投票のあとも A/B 画面が残っている")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "通常の画面(タブバー)が出ない")
    }

    func testZoomOpensAndClosesOnSamePair() {
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        waitForProgress("1/3")
        element("ab.imageA").tap()
        XCTAssertTrue(element("ab.zoom").waitForExistence(timeout: 5), "ズームが開かない")
        app.buttons["ab.zoomClose"].tap()
        let gone = NSPredicate(format: "exists == false")
        let exp = expectation(for: gone, evaluatedWith: element("ab.zoom"))
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: 5), .completed, "ズームが閉じない")
        XCTAssertTrue(element("ab.screen").exists)
        waitForProgress("1/3")
    }

    func testDoubleTapAdvancesOnlyOneStep() {
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        waitForProgress("1/3")
        app.buttons["ab.choiceA"].doubleTap()
        waitForProgress("2/3")
        // 偽サーバーの遅れ(0.6 秒)+余裕のあと、2 回目の投票が通って 3/3 になっていないこと
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(progress.label, "2/3")
    }
}
