import Foundation
import XCTest
@testable import azooKey

/// 会話モードの「黙って壊れない」規則(ConversePolicies.swift)。場面番号は portal-bot/docs/convmode-robustness-2026-10-28.md。
final class ConverseRobustTests: XCTestCase {
    // MARK: サーバーの新しいメッセージ(A1・A2)

    func testParsePing() {
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"ping","state":"working"}"#), .ping(state: "working"))
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"ping"}"#), .ping(state: nil))
    }

    func testParseSpeechFailedAndNotice() {
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"speech_failed","text":"返事です","sent":0}"#),
                       .speechFailed(text: "返事です", sent: 0))
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"speech_failed","text":"返事です","sent":7}"#),
                       .speechFailed(text: "返事です", sent: 7))
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"notice","code":"stt_slow","say":"文字起こしが遅れています"}"#),
                       .notice(code: "stt_slow", say: "文字起こしが遅れています"))
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"held","count":3}"#), .held(count: 3))
    }

    func testParseExistingMessagesUnchanged() {
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"state","state":"idle"}"#), .state("idle"))
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"transcript","text":"a","final":true}"#),
                       .transcript(text: "a", final: true))
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"audio","id":"x1","kind":"alert","bytes":10}"#),
                       .audio(.init(id: "x1", kind: "alert", format: "wav", bytes: 10)))
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"reply_text","text":"t"}"#), .replyText("t"))
        XCTAssertEqual(ConverseServerMessage.parse(#"{"type":"something_new"}"#), .unknown("something_new"))
        XCTAssertNil(ConverseServerMessage.parse("not json"), "壊れたフレームは捨てる")
        XCTAssertNil(ConverseServerMessage.parse(#"{"type":"audio"}"#), "id の無い audio は捨てる")
    }

    // MARK: 受信ウォッチドッグ(A1・S10 S13)

    func testRxWatchdogDropsAfter25sSilence() {
        var w = ConverseRxWatchdog()
        XCTAssertFalse(w.isStale(now: 100), "まだ開いていなければ張り直さない")
        w.touch(now: 0)
        XCTAssertFalse(w.isStale(now: 24.9))
        XCTAssertTrue(w.isStale(now: 25.1), "ping(10 秒ごと)が 2 回以上欠けたら半開き")
        w.touch(now: 20)
        XCTAssertFalse(w.isStale(now: 40), "何か届けば数え直す")
        w.reset()
        XCTAssertFalse(w.isStale(now: 1000))
    }

    // MARK: つながらない知らせ(A3・S11)

    func testOutageNotifierFirstAt20sThenEvery2min() {
        var n = ConverseOutageNotifier()
        n.began(now: 0)
        XCTAssertFalse(n.tick(now: 19))
        XCTAssertTrue(n.tick(now: 20), "20 秒つながらなければ 1 回目")
        XCTAssertFalse(n.tick(now: 60))
        XCTAssertFalse(n.tick(now: 139))
        XCTAssertTrue(n.tick(now: 140), "以後 2 分おき")
        XCTAssertTrue(n.tick(now: 260))
    }

    func testOutageNotifierSilentOnceConnected() {
        var n = ConverseOutageNotifier()
        n.began(now: 0)
        n.began(now: 15)  // 再接続の途中で connecting→reconnecting と来ても最初の時刻は変えない
        XCTAssertTrue(n.tick(now: 20))
        n.ended()
        XCTAssertFalse(n.tick(now: 200), "つながったら黙る")
        n.began(now: 300)
        XCTAssertFalse(n.tick(now: 310))
        XCTAssertTrue(n.tick(now: 320), "また切れたら 20 秒から数え直す")
    }

    // MARK: 端末側の読み上げの文(A2・S03 S04)

    func testSpeechFailedPhrase() {
        XCTAssertEqual(ConverseLocalPhrase.forSpeechFailed(text: " 返事の全文 \n", sent: 0), "返事の全文", "全滅なら本文を全部")
        XCTAssertEqual(ConverseLocalPhrase.forSpeechFailed(text: "返事の全文", sent: 3), ConverseLocalPhrase.continuationLost,
                       "途中からなら重ねて全部は読まない")
        XCTAssertNil(ConverseLocalPhrase.forSpeechFailed(text: "  ", sent: 0), "本文が空なら何も言わない")
    }

    // MARK: 再生ウォッチドッグ(A4・S17)

    func testPlaybackDeadlineIsLengthPlusGrace() {
        XCTAssertEqual(ConversePlaybackWatchdog.deadline(frames: 48_000, sampleRate: 24_000), 7, accuracy: 0.001)
        XCTAssertEqual(ConversePlaybackWatchdog.deadline(frames: 0, sampleRate: 24_000), 5, "壊れた wav でも 5 秒で次へ")
        XCTAssertEqual(ConversePlaybackWatchdog.deadline(frames: 100, sampleRate: 0), 5)
    }

    // MARK: 自動復帰(A4・S16 S18)

    func testRecoveryTriesTenTimesThenGivesUp() {
        var r = ConverseRecoveryPolicy()
        for i in 1...ConverseRecoveryPolicy.maxAttempts {
            XCTAssertEqual(r.nextDelay(), ConverseRecoveryPolicy.interval, "\(i) 回目")
        }
        XCTAssertNil(r.nextDelay(), "上限を超えたら諦めて知らせる")
        r.recovered()
        XCTAssertNotNil(r.nextDelay(), "復帰できたら数え直す")
    }

    // MARK: 経路変更(A5・S20)

    func testRouteChangeClassification() {
        XCTAssertEqual(ConverseRouteChange.classify(reasonRaw: 2), .deviceLost, "oldDeviceUnavailable")
        XCTAssertEqual(ConverseRouteChange.classify(reasonRaw: 1), .deviceGained, "newDeviceAvailable")
        XCTAssertEqual(ConverseRouteChange.classify(reasonRaw: 3), .other, "categoryChange")
        XCTAssertEqual(ConverseRouteChange.classify(reasonRaw: 999), .other)
    }

    func testHoldByRouteOnlyReleasesWhatItSet() {
        var h = ConverseHoldByRoute()
        XCTAssertFalse(h.gained(), "自分で掛けていない hold は外さない(本人が「返事ためる」と言った設定を壊さない)")
        XCTAssertTrue(h.lost(), "外れたら hold を掛ける")
        XCTAssertFalse(h.lost(), "二重に掛けない")
        XCTAssertTrue(h.gained(), "付いたら自分の hold を外す")
        XCTAssertFalse(h.gained())
        XCTAssertTrue(h.lost())
        h.reset()
        XCTAssertFalse(h.gained(), "会話モードを止めたら忘れる")
    }
}
