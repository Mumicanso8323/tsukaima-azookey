import Foundation
import XCTest
@testable import azooKey

final class AudioDiagTests: XCTestCase {
    func testDamperFirstThreeAreImmediateThenDelayed() {
        var d = ConverseRestartDamper()
        XCTAssertEqual(d.request(now: 0), .immediate)
        XCTAssertEqual(d.request(now: 1), .immediate)
        XCTAssertEqual(d.request(now: 2), .immediate)
        XCTAssertEqual(d.request(now: 3), .delay(1.5), "4 回目から遅らせる")
        XCTAssertEqual(d.recentCount, 4)
    }

    func testDamperMergesRequestsWhileWaiting() {
        var d = ConverseRestartDamper()
        for t in 0..<3 { _ = d.request(now: Double(t)) }
        let g = d.generation
        XCTAssertEqual(d.request(now: 3), .delay(1.5))
        XCTAssertEqual(d.request(now: 3.2), .merged)
        XCTAssertEqual(d.request(now: 3.4), .merged)
        XCTAssertTrue(d.fire(generation: g), "待ちが終わったら 1 回だけ再起動する")
        XCTAssertFalse(d.fire(generation: g), "同じ待ちで 2 回は再起動しない")
    }

    func testDamperWaitGrowsWhileFlappingContinues() {
        var d = ConverseRestartDamper()
        for t in 0..<3 { _ = d.request(now: Double(t) * 0.1) }
        XCTAssertEqual(d.request(now: 0.3), .delay(1.5))
        let g = d.generation
        XCTAssertTrue(d.fire(generation: g))
        XCTAssertEqual(d.request(now: 1.8), .delay(1.5))   // 5 件目
        XCTAssertTrue(d.fire(generation: g))
        XCTAssertEqual(d.request(now: 3.3), .delay(1.5))   // 6 件目
        XCTAssertTrue(d.fire(generation: g))
        XCTAssertEqual(d.request(now: 4.8), .delay(3.0), "7 件目からは待ちを伸ばす")
    }

    func testDamperReturnsToNormalAfterQuietWindow() {
        var d = ConverseRestartDamper()
        for t in 0..<5 { _ = d.request(now: Double(t) * 0.1) }
        let g = d.generation
        XCTAssertTrue(d.fire(generation: g))
        XCTAssertEqual(d.request(now: 20), .immediate, "10 秒より長く止まれば通常に戻る")
        XCTAssertEqual(d.recentCount, 1)
    }

    func testDamperCancelDiscardsPendingRestart() {
        var d = ConverseRestartDamper()
        for t in 0..<3 { _ = d.request(now: Double(t)) }
        let g = d.generation
        XCTAssertEqual(d.request(now: 3), .delay(1.5))
        d.cancel()
        XCTAssertFalse(d.fire(generation: g), "stop された古い世代は捨てる")
        XCTAssertEqual(d.request(now: 3.1), .immediate, "履歴も捨てる")
    }

    func testLogLimiterCapsLinesAndReportsSuppressed() {
        var l = AudioDiagLimiter(maxLines: 40, window: 10)
        for i in 0..<40 { XCTAssertEqual(l.admit(now: Double(i) * 0.1), .emit) }
        XCTAssertEqual(l.admit(now: 5), .drop)
        XCTAssertEqual(l.admit(now: 6), .drop)
        XCTAssertEqual(l.admit(now: 10.5), .emitAfterSuppressed(2))
        XCTAssertEqual(l.admit(now: 10.6), .emit)
    }

    @MainActor
    func testBeepDoesNotTouchSessionWhileSomeoneElseOwnsIt() {
        let busy = BlindTonePlayer(isSessionBusy: { true }, deactivate: {})
        busy.prepareSession()
        busy.prepareSession()
        XCTAssertEqual(busy.configureSessionCount, 0, "会話などが握っている間はカテゴリに触らない")
    }
}
