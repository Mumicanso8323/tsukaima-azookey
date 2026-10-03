//
//  PerfStallUITests.swift
//  Claude タブの「メインスレッドの詰まり」を測るだけのテスト(合否は付けない)。旧表示と新表示を同じ条件で比べるために使う。
//  偽サーバーが履歴を流している間(最初の約 12 秒(40 回分))に、入力欄へ打ちながら、詰まりの回数と最大を ClaudeFocusProbe から読んで出す。
//

import XCTest

final class PerfStallUITests: XCTestCase {
    func testMeasureMainThreadStalls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--claude-mock", "--claude-mock-stream"]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "claude.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        let probe = app.descendants(matching: .any).matching(identifier: "claude.debug.focus").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        // 入力はせず、履歴が流れているあいだの画面だけを測る(入力の影響を混ぜない)。
        Thread.sleep(forTimeInterval: 11)
        print("PERFSTALL: \(probe.label)")
        XCTContext.runActivity(named: probe.label) { _ in }
    }
}
