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

/// 音声の呼び出しから Swift の trap を起こさない判定(AudioSafe)の試験。
/// 落ちた trap の代わりに、変換できない値は nil・-1 で返すことを確かめる。
final class AudioSafeTests: XCTestCase {
    func testIntConversionRejectsNonFiniteAndOutOfRange() {
        XCTAssertNil(AudioSafe.int(.nan))
        XCTAssertNil(AudioSafe.int(.infinity))
        XCTAssertNil(AudioSafe.int(-.infinity))
        XCTAssertNil(AudioSafe.int(1e300))
        XCTAssertEqual(AudioSafe.int(48000), 48000)
        XCTAssertEqual(AudioSafe.int(8000.9), 8000)
        XCTAssertEqual(AudioSafe.display(.nan), -1)
        XCTAssertEqual(AudioSafe.display(44100), 44100)
    }

    func testFormatUsableNeedsPositiveFiniteRateAndChannel() {
        XCTAssertTrue(AudioSafe.usable(sampleRate: 48000, channels: 1))
        XCTAssertTrue(AudioSafe.usable(sampleRate: 8000, channels: 2))
        XCTAssertFalse(AudioSafe.usable(sampleRate: 0, channels: 1))
        XCTAssertFalse(AudioSafe.usable(sampleRate: 48000, channels: 0))
        XCTAssertFalse(AudioSafe.usable(sampleRate: .nan, channels: 1))
        XCTAssertFalse(AudioSafe.usable(sampleRate: .infinity, channels: 1))
        XCTAssertFalse(AudioSafe.usable(sampleRate: -16000, channels: 1))
    }

    func testFrameCapacityIsNilWhenRatioIsNotUsable() {
        XCTAssertEqual(AudioSafe.frameCapacity(frames: 4096, ratio: 1.0), 4096 + 64)
        XCTAssertEqual(AudioSafe.frameCapacity(frames: 9600, ratio: 0.5), 4800 + 64)
        XCTAssertNil(AudioSafe.frameCapacity(frames: 4096, ratio: .infinity))
        XCTAssertNil(AudioSafe.frameCapacity(frames: 4096, ratio: .nan))
        XCTAssertNil(AudioSafe.frameCapacity(frames: 4096, ratio: -1))
        XCTAssertNil(AudioSafe.frameCapacity(frames: UInt32.max, ratio: 1e6))
    }
}
