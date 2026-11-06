//
//  TsukaimaAutoScheduleTests.swift
//  授業の自動録音(開始してよい時間帯)と、技能教習の消音(残り秒数。学科では 0)の判定
//

import Foundation
import XCTest
@testable import azooKey

final class TsukaimaAutoScheduleTests: XCTestCase {
    private func t(_ hm: String) -> Date {
        ISO8601DateFormatter().date(from: "2026-11-07T\(hm):00+09:00")!
    }

    private func schedule(_ json: String) throws -> TsukaimaAutoSchedule {
        try XCTUnwrap(TsukaimaAutoSchedule.parse(Data(json.utf8)))
    }

    private let sample = """
    {"now":"2026-11-07T10:55:00+09:00",
     "classes":[{"id":"a","title":"計測工学","start":"2026-11-07T10:50:00+09:00","end":"2026-11-07T12:20:00+09:00"},
                {"id":"b","title":"電子回路工学","start":"2026-11-07T13:10:00+09:00","end":"2026-11-07T14:40:00+09:00"}],
     "driving":{"active":true,"start":"2026-11-07T10:50:00+09:00","until":"2026-11-07T12:40:00+09:00",
                "next_start":"2026-11-07T15:50:00+09:00","next_until":"2026-11-07T16:40:00+09:00"}}
    """

    func testRecordsOnlyFromFifteenMinutesBeforeStartUntilEnd() throws {
        let s = try schedule(sample)
        XCTAssertNil(s.classToRecord(at: t("10:30")), "開始の20分前はまだ始めない")
        XCTAssertEqual(s.classToRecord(at: t("10:36"))?.title, "計測工学")
        XCTAssertEqual(s.classToRecord(at: t("11:30"))?.title, "計測工学")
        XCTAssertNil(s.classToRecord(at: t("12:30")), "授業のあいだ以外は始めない")
        XCTAssertEqual(s.classToRecord(at: t("13:00"))?.title, "電子回路工学")
    }

    func testSilenceDuringPracticalIsRemainingSeconds() throws {
        let s = try schedule(sample)
        XCTAssertEqual(s.silenceSeconds(at: t("12:00")), 40 * 60)
    }

    func testLectureOnlyDayDoesNotSilence() throws {
        let s = try schedule("""
        {"now":"2026-11-07T17:00:00+09:00","classes":[],
         "driving":{"active":false,"start":null,"until":null,"next_start":null,"next_until":null}}
        """)
        XCTAssertEqual(s.silenceSeconds(at: t("17:00")), 0, "学科だけなら鳴ったまま")
    }

    func testNextPracticalSilencesOnlyWhenImminent() throws {
        let s = try schedule("""
        {"now":"2026-11-07T15:00:00+09:00","classes":[],
         "driving":{"active":false,"start":null,"until":null,"next_start":"2026-11-07T15:50:00+09:00","next_until":"2026-11-07T16:40:00+09:00"}}
        """)
        XCTAssertEqual(s.silenceSeconds(at: t("15:00")), 0, "50分前から消音にはしない")
        XCTAssertEqual(s.silenceSeconds(at: t("15:40")), 60 * 60, "開始10分前に着いたら終わりまで消音")
    }

    func testBadResponseIsNil() {
        XCTAssertNil(TsukaimaAutoSchedule.parse(Data("{}".utf8)))
    }
}
