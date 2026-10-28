//
//  RateGateUITests.swift
//  1--10 採点ゲートを偽サーバー(`--rate-mock`)で確認する。
//

import XCTest

final class RateGateUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        launch(["--rate-mock"])
    }

    private func launch(_ arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var progress: XCUIElement { app.staticTexts["rate.progress"] }

    private func waitForProgress(_ text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@", text)
        let expectation = expectation(for: predicate, evaluatedWith: progress)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "progress が \(text) にならない(いま: \(progress.label))", file: file, line: line)
    }

    func testGateAppearsAtLaunchWithScaleAndAllScores() {
        XCTAssertTrue(element("rate.screen").waitForExistence(timeout: 20))
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        waitForProgress("1/3")
        XCTAssertEqual(element("rate.low").label, "全然ダメ")
        XCTAssertEqual(element("rate.high").label, "最高")
        for score in 1...10 {
            XCTAssertTrue(element("rate.score.\(score)").exists, "score \(score) が無い")
        }
    }

    func testScoresThroughAllItemsThenReturnsToNormalUI() {
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        waitForProgress("1/3")
        element("rate.score.7").tap()
        waitForProgress("2/3")
        element("rate.score.1").tap()
        waitForProgress("3/3")
        element("rate.score.10").tap()
        let gone = NSPredicate(format: "exists == false")
        let expectation = expectation(for: gone, evaluatedWith: element("rate.screen"))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "通常の画面(タブバー)が出ない")
    }

    func testDoubleTapAdvancesOnlyOneStep() {
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        waitForProgress("1/3")
        element("rate.score.5").doubleTap()
        waitForProgress("2/3")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(progress.label, "2/3")
    }

    func testZoomReturnsToSameItem() {
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        waitForProgress("1/3")
        element("rate.image").tap()
        XCTAssertTrue(element("rate.zoom").waitForExistence(timeout: 5), "ズームが開かない")
        element("rate.zoomClose").tap()
        let gone = NSPredicate(format: "exists == false")
        let expectation = expectation(for: gone, evaluatedWith: element("rate.zoom"))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed)
        waitForProgress("1/3")
    }

    func testRatingIsFirstThenABWhenBothMocksPending() {
        app.terminate()
        launch(["--rate-mock", "--ab-mock"])
        XCTAssertTrue(element("rate.screen").waitForExistence(timeout: 20))
        waitForProgress("1/3")
        element("rate.score.1").tap()
        waitForProgress("2/3")
        element("rate.score.1").tap()
        waitForProgress("3/3")
        element("rate.score.1").tap()
        XCTAssertTrue(element("ab.screen").waitForExistence(timeout: 10), "採点完了後の A/B が出ない")
        XCTAssertEqual(app.staticTexts["ab.progress"].label, "1/3")
    }
}
