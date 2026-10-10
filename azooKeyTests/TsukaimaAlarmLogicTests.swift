//
//  TsukaimaAlarmLogicTests.swift
//  使い魔の目覚ましの純ロジック(再起動時の復元・前面化時の点検・AlarmKit の保険の検証・hub への報告)のテスト
//

import Foundation
import XCTest
@testable import azooKey

final class TsukaimaAlarmLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var future: Date { now.addingTimeInterval(3600) }
    private var past: Date { now.addingTimeInterval(-3600) }

    // MARK: AlarmRestoreLogic.decide(プロセス再起動)

    func testRestoreArmedFutureRearms() {
        XCTAssertEqual(AlarmRestoreLogic.decide(phase: .armed, fireAt: future, checkDeadline: nil, now: now), .rearm(fireAt: future))
    }

    func testRestoreArmedPastRingsNow() {
        XCTAssertEqual(AlarmRestoreLogic.decide(phase: .armed, fireAt: past, checkDeadline: nil, now: now), .ringNow)
    }

    func testRestoreRingingAlwaysRingsNow() {
        XCTAssertEqual(AlarmRestoreLogic.decide(phase: .ringing, fireAt: past, checkDeadline: nil, now: now), .ringNow)
        XCTAssertEqual(AlarmRestoreLogic.decide(phase: .ringing, fireAt: nil, checkDeadline: nil, now: now), .ringNow)
    }

    func testRestoreCheckingHonoursDeadline() {
        XCTAssertEqual(AlarmRestoreLogic.decide(phase: .checking, fireAt: past, checkDeadline: future, now: now), .resumeChecking(deadline: future))
        XCTAssertEqual(AlarmRestoreLogic.decide(phase: .checking, fireAt: past, checkDeadline: past, now: now), .ringNow)
        XCTAssertEqual(AlarmRestoreLogic.decide(phase: .checking, fireAt: past, checkDeadline: nil, now: now), .ringNow)
    }

    func testRestoreOffOrBrokenArmedDoesNothing() {
        XCTAssertEqual(AlarmRestoreLogic.decide(phase: .off, fireAt: future, checkDeadline: nil, now: now), .doNothing)
        XCTAssertEqual(AlarmRestoreLogic.decide(phase: .armed, fireAt: nil, checkDeadline: nil, now: now), .doNothing)
    }

    // MARK: AlarmRestoreLogic.foreground(前面化のたびの点検)

    func testForegroundArmedFutureKeepsAliveWithBackupAtFireAt() {
        // 本番の保険は定刻ちょうど(1 分遅らせない)
        XCTAssertEqual(AlarmRestoreLogic.foreground(phase: .armed, fireAt: future, checkDeadline: nil, now: now), .keepAlive(backupAt: future))
    }

    func testForegroundArmedPastRingsNow() {
        XCTAssertEqual(AlarmRestoreLogic.foreground(phase: .armed, fireAt: past, checkDeadline: nil, now: now), .ringNow)
    }

    func testForegroundRingingOnlyResumes() {
        // 鳴っている最中に前面へ来ても、問題を作り直したり止めたりしない
        XCTAssertEqual(AlarmRestoreLogic.foreground(phase: .ringing, fireAt: past, checkDeadline: nil, now: now), .resumeRinging)
    }

    func testForegroundCheckingBackupIsDeadlinePlusDelay() {
        let expected = future.addingTimeInterval(AlarmRestoreLogic.checkBackupDelay)
        XCTAssertEqual(AlarmRestoreLogic.foreground(phase: .checking, fireAt: past, checkDeadline: future, now: now), .keepAlive(backupAt: expected))
        XCTAssertEqual(AlarmRestoreLogic.foreground(phase: .checking, fireAt: past, checkDeadline: past, now: now), .ringNow)
        XCTAssertEqual(AlarmRestoreLogic.foreground(phase: .checking, fireAt: past, checkDeadline: nil, now: now), .ringNow)
    }

    func testForegroundOffOrBrokenArmedDoesNothing() {
        XCTAssertEqual(AlarmRestoreLogic.foreground(phase: .off, fireAt: future, checkDeadline: nil, now: now), .doNothing)
        XCTAssertEqual(AlarmRestoreLogic.foreground(phase: .armed, fireAt: nil, checkDeadline: nil, now: now), .doNothing)
    }

    // MARK: AlarmBackupLogic.verify(AlarmKit の保険が OS に残っているか)

    func testBackupVerifyOkWhenStoredAndStillScheduled() {
        let id = UUID()
        XCTAssertEqual(AlarmBackupLogic.verify(expected: future, storedID: id, storedAt: future, scheduledIDs: [id, UUID()]), .ok)
        // 1 秒未満の誤差は同じ時刻とみなす
        XCTAssertEqual(AlarmBackupLogic.verify(expected: future, storedID: id, storedAt: future.addingTimeInterval(0.5), scheduledIDs: [id]), .ok)
    }

    func testBackupVerifyMissingWhenOSDroppedIt() {
        // 2026-10-01 の実機: 置いた記録はあるのに OS から消えていた(アプリの入れ直し)
        let id = UUID()
        XCTAssertEqual(AlarmBackupLogic.verify(expected: future, storedID: id, storedAt: future, scheduledIDs: []), .reschedule(reason: "missing"))
    }

    func testBackupVerifyStaleWhenTimeDiffers() {
        let id = UUID()
        XCTAssertEqual(AlarmBackupLogic.verify(expected: future, storedID: id, storedAt: future.addingTimeInterval(60), scheduledIDs: [id]), .reschedule(reason: "stale"))
    }

    func testBackupVerifyNoneWhenNeverStored() {
        XCTAssertEqual(AlarmBackupLogic.verify(expected: future, storedID: nil, storedAt: nil, scheduledIDs: []), .reschedule(reason: "none"))
        XCTAssertEqual(AlarmBackupLogic.verify(expected: future, storedID: UUID(), storedAt: nil, scheduledIDs: []), .reschedule(reason: "none"))
    }

    // MARK: AlarmStateReport.payload(hub への報告)

    func testReportPayloadIsJSONSerializableWithISO8601FireAt() throws {
        let id = UUID()
        let payload = AlarmStateReport.payload(phase: .armed, fireAt: now, backupScheduled: true, backupID: id, appBuild: "61")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertEqual(payload["phase"] as? String, "armed")
        XCTAssertEqual(payload["backupScheduled"] as? Bool, true)
        XCTAssertEqual(payload["backupId"] as? String, id.uuidString)
        XCTAssertEqual(payload["appBuild"] as? String, "61")
        let iso = try XCTUnwrap(payload["fireAt"] as? String)
        XCTAssertEqual(ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970, now.timeIntervalSince1970)
    }

    func testReportPayloadUsesNullWhenOff() {
        let payload = AlarmStateReport.payload(phase: .off, fireAt: nil, backupScheduled: false, backupID: nil, appBuild: "61")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertTrue(payload["fireAt"] is NSNull)
        XCTAssertTrue(payload["backupId"] is NSNull)
        XCTAssertEqual(payload["phase"] as? String, "off")
    }
}
