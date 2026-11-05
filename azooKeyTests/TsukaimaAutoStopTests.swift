//
//  TsukaimaAutoStopTests.swift
//  授業録音の自動停止: サーバーの合図の解釈と、アプリ側の保険の方針(時間割どおり止まる・時間割外は止めない・延長で止めない)
//

import Foundation
import XCTest
@testable import azooKey

final class TsukaimaAutoStopTests: XCTestCase {
    func testStartCarriesStopAtForTimetableRecording() {
        let m = TsukaimaUplink.parse(#"{"type":"start","lecture":7,"course":"DE基礎","end":"2026-11-04T14:40:00+09:00","stop_at":"2026-11-04T14:50:00+09:00"}"#)
        guard case let .start(id, course, end, stopAt)? = m else { return XCTFail("start を読めない") }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(course, "DE基礎")
        XCTAssertNotNil(end)
        // 授業の終了のちょうど10分後(時間割どおり)
        XCTAssertEqual(stopAt?.timeIntervalSince(end!), 600)
    }

    func testManualRecordingHasNoStopTimeAndNoFallbackTimer() {
        let m = TsukaimaUplink.parse(#"{"type":"start","lecture":8,"course":null,"end":null,"stop_at":null}"#)
        guard case let .start(_, _, _, stopAt)? = m else { return XCTFail("start を読めない") }
        XCTAssertNil(stopAt)
        XCTAssertNil(TsukaimaAutoStopPolicy.fallbackDeadline(stopAt: stopAt), "時間割外の録音は保険のタイマーも置かない = 止めない")
    }

    func testFallbackIsAfterServerStopTime() {
        let stop = Date(timeIntervalSince1970: 1_800_000_000)
        let d = TsukaimaAutoStopPolicy.fallbackDeadline(stopAt: stop)
        XCTAssertEqual(d, stop.addingTimeInterval(TsukaimaAutoStopPolicy.fallbackMargin))
        XCTAssertGreaterThan(d!, stop, "サーバーの判定より先にアプリが止めない")
    }

    func testExtendScheduleMovesFallbackLater() {
        let first = TsukaimaUplink.parse(#"{"type":"warn","stop_at":"2026-11-04T14:50:00+09:00"}"#)
        let ext = TsukaimaUplink.parse(#"{"type":"schedule","stop_at":"2026-11-04T15:05:00+09:00"}"#)
        guard case let .warn(a)? = first, case let .schedule(b)? = ext else { return XCTFail("読めない") }
        let before = TsukaimaAutoStopPolicy.fallbackDeadline(stopAt: a)!
        let after = TsukaimaAutoStopPolicy.fallbackDeadline(stopAt: b)!
        XCTAssertEqual(after.timeIntervalSince(before), 15 * 60, "延長すると停止の保険も15分後ろへ動く")
    }

    func testAutoStopAndDoneAndUnknown() {
        XCTAssertEqual(TsukaimaUplink.parse(#"{"type":"auto_stop","reason":"自動停止"}"#), .autoStop(reason: "自動停止"))
        XCTAssertEqual(TsukaimaUplink.parse(#"{"type":"done","lecture":1}"#), .done)
        XCTAssertEqual(TsukaimaUplink.parse(#"{"type":"text","text":"こんにちは"}"#), .text("こんにちは"))
        XCTAssertNil(TsukaimaUplink.parse(#"{"type":"text","text":""}"#))
        XCTAssertNil(TsukaimaUplink.parse(#"{"type":"unknown"}"#))
        XCTAssertNil(TsukaimaUplink.parse("not json"))
    }
}
