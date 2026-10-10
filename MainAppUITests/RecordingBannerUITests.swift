import XCTest

/// 録音中の赤い帯が、上部のセグメント(使い魔の内側タブなど)を隠さないことを確かめる。
/// `--rec-mock` はマイク・送信・権限確認なしで、最初から録音中にする。
final class RecordingBannerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["--claude-mock", "--rec-mock"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func assertPickerClear(_ id: String, segments: [String], file: StaticString = #filePath, line: UInt = #line) {
        let banner = element("rec.banner")
        let picker = element(id)
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "rec.banner が無い", file: file, line: line)
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "\(id) が無い", file: file, line: line)
        XCTAssertTrue(picker.isHittable, "\(id) が押せない(帯が覆っている疑い) picker=\(picker.frame) banner=\(banner.frame)", file: file, line: line)
        for s in segments {
            let b = picker.buttons[s]
            XCTAssertTrue(b.exists, "\(id) の「\(s)」が無い", file: file, line: line)
            XCTAssertTrue(b.isHittable, "\(id) の「\(s)」が押せない segment=\(b.frame) banner=\(banner.frame)", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(picker.frame.minY, banner.frame.maxY - 1,
                                    "\(id) が帯と重なっている picker=\(picker.frame) banner=\(banner.frame)", file: file, line: line)
    }

    func testTsukaimaInnerTabsNotCoveredByBanner() {
        XCTAssertTrue(app.tabBars.buttons["使い魔"].waitForExistence(timeout: 20))
        app.tabBars.buttons["使い魔"].tap()
        assertPickerClear("tsukaima.innerTabs", segments: ["チャット", "録音"])
    }

    func testHomeSegmentsNotCoveredByBanner() {
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 20))
        app.tabBars.buttons["ホーム"].tap()
        assertPickerClear("home.segments", segments: ["今日", "勉強"])
    }

    func testSettingsSectionsNotCoveredByBanner() {
        // 「設定」はラベルで引けなかったので、右端(4 番目)のボタンを押す
        let tab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        assertPickerClear("settings.sections", segments: ["使い魔", "キーボード"])
    }

    func testClaudeTopBarNotCoveredByBanner() {
        let tab = app.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        assertPickerClear("claude.topbar", segments: [])
    }
}
