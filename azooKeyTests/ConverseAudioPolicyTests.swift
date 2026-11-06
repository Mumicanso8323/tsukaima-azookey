import Foundation
import XCTest
@testable import azooKey

final class ConverseAudioPolicyTests: XCTestCase {
    func testAutoUsesHeadsetOnlyWhenHFPOutputIsActive() {
        XCTAssertEqual(ConverseMicMode.builtIn.resolve(hfpOutputActive: true), .builtIn)
        XCTAssertEqual(ConverseMicMode.headset.resolve(hfpOutputActive: false), .headset)
        XCTAssertEqual(ConverseMicMode.auto.resolve(hfpOutputActive: true), .headset)
        XCTAssertEqual(ConverseMicMode.auto.resolve(hfpOutputActive: false), .builtIn)
    }

    func testVoiceProcessingSkippedForBuiltInMicWithBluetoothOutput() {
        XCTAssertFalse(ConverseAudioPolicy.useVoiceProcessing(choice: .builtIn, bluetoothOutput: true))
        XCTAssertTrue(ConverseAudioPolicy.useVoiceProcessing(choice: .builtIn, bluetoothOutput: false))
        XCTAssertTrue(ConverseAudioPolicy.useVoiceProcessing(choice: .headset, bluetoothOutput: true))
    }

    func testTapJudge() {
        var s = ConverseTapStats(launchedAt: 0)
        XCTAssertEqual(ConverseTapJudge.judge(s, now: 1), .waiting)
        XCTAssertEqual(ConverseTapJudge.judge(s, now: 3), .noCallbacks)
        s.add(frames: 4096, sumSquares: 0, peak: 0, now: 7.5)
        XCTAssertEqual(ConverseTapJudge.judge(s, now: 8), .allZero, "起動から 8 秒 0 だけ")
        s.add(frames: 4096, sumSquares: 1, peak: 0.1, now: 8)
        XCTAssertEqual(ConverseTapJudge.judge(s, now: 9), .healthy)
        XCTAssertEqual(ConverseTapJudge.judge(s, now: 12), .stalled)
    }

    func testRecoveryEscalates() {
        XCTAssertEqual(ConverseRecovery.step(attempt: 1, choice: .headset), .rebuildEngine)
        XCTAssertEqual(ConverseRecovery.step(attempt: 2, choice: .headset), .rebuildWithoutVP)
        XCTAssertEqual(ConverseRecovery.step(attempt: 3, choice: .headset), .fallbackToBuiltIn)
        XCTAssertEqual(ConverseRecovery.step(attempt: 3, choice: .builtIn), .giveUp)
        XCTAssertEqual(ConverseRecovery.step(attempt: 4, choice: .headset), .giveUp)
    }

    func testRestartCapStopsLoop() {
        var c = ConverseRestartCap()
        let ok = (0..<12).filter { c.allow(now: Double($0)) }.count
        XCTAssertEqual(ok, ConverseAudioPolicy.restartCap)
        XCTAssertTrue(c.allow(now: 100), "窓を過ぎれば再び許す")
    }
}
