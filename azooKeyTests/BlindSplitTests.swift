import AVFoundation
import Combine
import Foundation
import XCTest
@testable import azooKey

private func makeReply(
    rid: Int = 1, epoch: String = "e1", text: String = "こんにちは", question: Bool = false,
    at: Double = 1_000, replay: Bool = false, audio: BlindReply.Audio = .muted
) -> BlindReply {
    BlindReply(rid: rid, epoch: epoch, text: text, question: question, at: at, origin: "voice",
               replay: replay, audio: audio, why: nil)
}

/// 純粋な規則(出し方・カードの長さ・重複・振動の判断・経路・メッセージの読み取り)。
final class BlindSplitLogicTests: XCTestCase {
    // MARK: 出し方

    func testOutputModeNextOrder() {
        XCTAssertEqual(BlindOutputMode.voice.next(), .text)
        XCTAssertEqual(BlindOutputMode.text.next(), .both)
        XCTAssertEqual(BlindOutputMode.both.next(), .voice)
    }

    func testOutputModeRestoreFallsBackToVoice() {
        XCTAssertEqual(BlindOutputMode.restored(from: nil), .voice)
        XCTAssertEqual(BlindOutputMode.restored(from: "garbage"), .voice)
        XCTAssertEqual(BlindOutputMode.restored(from: "text"), .text)
        XCTAssertEqual(BlindOutputMode.restored(from: "both"), .both)
    }

    func testOutputModeStorePersistsAndRestores() throws {
        let name = "blind.split.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BlindOutputModeStore(defaults: defaults)
        XCTAssertEqual(store.load(), .voice)
        store.save(.text)
        XCTAssertEqual(BlindOutputModeStore(defaults: defaults).load(), .text)
        defaults.set("???", forKey: BlindOutputModeStore.key)
        XCTAssertEqual(store.load(), .voice)
        XCTAssertFalse(store.loadBothHaptics())
        store.saveBothHaptics(true)
        XCTAssertTrue(store.loadBothHaptics())
    }

    func testOutputModeFlags() {
        XCTAssertTrue(BlindOutputMode.voice.playsAudio)
        XCTAssertTrue(BlindOutputMode.both.playsAudio)
        XCTAssertFalse(BlindOutputMode.text.playsAudio)
        XCTAssertTrue(BlindOutputMode.text.vibratesByDefault)
        XCTAssertFalse(BlindOutputMode.both.vibratesByDefault)
    }

    // MARK: 返事カードの長さ

    func testPreviewKeepsTextUpTo240() {
        let at239 = String(repeating: "あ", count: 239)
        let at240 = String(repeating: "あ", count: 240)
        XCTAssertFalse(BlindReplyLayout.preview(at239).isTruncated)
        XCTAssertEqual(BlindReplyLayout.preview(at239).displayText, at239)
        XCTAssertFalse(BlindReplyLayout.preview(at240).isTruncated)
        XCTAssertEqual(BlindReplyLayout.preview(at240).displayText, at240)
    }

    func testPreviewTruncatesAt241WithTotal() {
        let text = String(repeating: "あ", count: 241)
        let preview = BlindReplyLayout.preview(text)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(preview.total, 241)
        XCTAssertEqual(preview.shown.count, 240)
        XCTAssertEqual(preview.displayText, String(repeating: "あ", count: 240) + "…(全 241 字)")
        // 全文シートに渡すのは元の文字列
        XCTAssertEqual(text.count, 241)
    }

    func testPreviewCountsSurrogatePairsAndNewlinesAsOne() {
        let emoji = String(repeating: "😀", count: 240)
        XCTAssertFalse(BlindReplyLayout.preview(emoji).isTruncated)
        XCTAssertTrue(BlindReplyLayout.preview(emoji + "😀").isTruncated)
        XCTAssertEqual(BlindReplyLayout.preview(emoji + "😀").shown, emoji)
        let lines = String(repeating: "a\n", count: 121)  // 242 文字
        XCTAssertEqual(lines.count, 242)
        XCTAssertTrue(BlindReplyLayout.preview(lines).isTruncated)
        XCTAssertEqual(BlindReplyLayout.preview(lines).shown.count, 240)
    }

    // MARK: 重複(epoch/rid)

    func testDeduperDropsSameAndLowerRidInSameEpoch() {
        var d = BlindReplyDeduper()
        XCTAssertTrue(d.accept(epoch: "e1", rid: 5))
        XCTAssertFalse(d.accept(epoch: "e1", rid: 5))
        XCTAssertFalse(d.accept(epoch: "e1", rid: 4))
        XCTAssertTrue(d.accept(epoch: "e1", rid: 6))
    }

    func testDeduperAcceptsNewEpochAndResetsBase() {
        var d = BlindReplyDeduper()
        XCTAssertTrue(d.accept(epoch: "e1", rid: 9))
        XCTAssertTrue(d.accept(epoch: "e2", rid: 1))  // サーバー再起動: rid が戻っても受ける
        XCTAssertFalse(d.accept(epoch: "e2", rid: 1))
        XCTAssertTrue(d.accept(epoch: "e2", rid: 2))
    }

    func testDeduperRestoredFromStoredMarkerDropsReplayOfSeenReply() {
        var d = BlindReplyDeduper(epoch: "e1", rid: 3)
        XCTAssertFalse(d.accept(epoch: "e1", rid: 3))
        XCTAssertFalse(d.accept(epoch: "e1", rid: 2))
        XCTAssertTrue(d.accept(epoch: "e1", rid: 4))
    }

    // MARK: 振動の判断

    func testHapticReplyInTextIsOnce() {
        let p = BlindHapticDecision.replyPattern(reply: makeReply(), mode: .text, bothHaptics: false,
                                                 claudeTabFrontmostAndActive: false, now: 1_100)
        XCTAssertEqual(p, .reply)
    }

    func testHapticQuestionIsTwoPulsePattern() {
        let p = BlindHapticDecision.replyPattern(reply: makeReply(question: true), mode: .text, bothHaptics: false,
                                                 claudeTabFrontmostAndActive: false, now: 1_100)
        XCTAssertEqual(p, .replyQuestion)
    }

    func testHapticVoiceNeverAndBothOnlyWithFlag() {
        XCTAssertNil(BlindHapticDecision.replyPattern(reply: makeReply(), mode: .voice, bothHaptics: true,
                                                      claudeTabFrontmostAndActive: false, now: 1_100))
        XCTAssertNil(BlindHapticDecision.replyPattern(reply: makeReply(), mode: .both, bothHaptics: false,
                                                      claudeTabFrontmostAndActive: false, now: 1_100))
        XCTAssertEqual(BlindHapticDecision.replyPattern(reply: makeReply(), mode: .both, bothHaptics: true,
                                                        claudeTabFrontmostAndActive: false, now: 1_100), .reply)
    }

    func testHapticReplayOlderThan30MinutesIsSilent() {
        let old = makeReply(at: 1_000, replay: true)
        XCTAssertNil(BlindHapticDecision.replyPattern(reply: old, mode: .text, bothHaptics: false,
                                                      claudeTabFrontmostAndActive: false, now: 1_000 + 2_101))
        XCTAssertEqual(BlindHapticDecision.replyPattern(reply: old, mode: .text, bothHaptics: false,
                                                        claudeTabFrontmostAndActive: false, now: 1_000 + 2_100), .reply)
        // 再送でない返事は古くても(届いた時点で)振動する
        let live = makeReply(at: 1_000, replay: false)
        XCTAssertEqual(BlindHapticDecision.replyPattern(reply: live, mode: .text, bothHaptics: false,
                                                        claudeTabFrontmostAndActive: false, now: 9_999), .reply)
    }

    func testHapticSuppressedWhenClaudeTabFrontmostAndActive() {
        XCTAssertNil(BlindHapticDecision.replyPattern(reply: makeReply(), mode: .text, bothHaptics: false,
                                                      claudeTabFrontmostAndActive: true, now: 1_100))
    }

    func testBeepToHapticMapping() {
        XCTAssertEqual(BlindHapticPattern.pattern(for: .sent), .sent)
        XCTAssertEqual(BlindHapticPattern.pattern(for: .error), .error)
        XCTAssertEqual(BlindHapticPattern.pattern(for: .readDenied), .cannotRead)
        XCTAssertEqual(BlindHapticPattern.pattern(for: .noListener), .cannotRead)
        XCTAssertEqual(BlindHapticPattern.pattern(for: .enter), .enter)
        XCTAssertNotEqual(BlindHapticPattern.pattern(for: .enter), BlindHapticPattern.pattern(for: .exit))
        // どの beep にも振動が決まっている
        for beep in BlindBeep.allCases { _ = BlindHapticPattern.pattern(for: beep) }
    }

    // MARK: 経路

    func testRouteClassification() {
        XCTAssertEqual(BlindRoute.classify(outputs: [.builtInSpeaker]), .speaker)
        XCTAssertEqual(BlindRoute.classify(outputs: [.builtInReceiver]), .speaker)
        XCTAssertEqual(BlindRoute.classify(outputs: []), .speaker)
        XCTAssertEqual(BlindRoute.classify(outputs: [.headphones]), .privateOutput)
        XCTAssertEqual(BlindRoute.classify(outputs: [.bluetoothA2DP]), .privateOutput)
        XCTAssertEqual(BlindRoute.classify(outputs: [.bluetoothHFP]), .privateOutput)
        XCTAssertEqual(BlindRoute.classify(outputs: [.carAudio]), .privateOutput)
        XCTAssertEqual(BlindRoute.classify(outputs: [.HDMI]), .speaker)
        XCTAssertEqual(BlindRoute.classify(outputs: [.builtInSpeaker, .headphones]), .privateOutput)
        XCTAssertEqual(BlindRoute.privateOutput.rawValue, "private")
        XCTAssertEqual(BlindRoute.speaker.rawValue, "speaker")
    }

    // MARK: 音声の門

    func testAudioGateRules() {
        func accept(_ mode: BlindOutputMode, _ route: BlindRoute, full: Bool = false, armed: Bool = false, proto2: Bool = true) -> Bool {
            BlindAudioGate.accept(proto2: proto2, mode: mode, route: route, fullConversationRunning: full, readArmed: armed)
        }
        XCTAssertTrue(accept(.voice, .speaker))
        XCTAssertTrue(accept(.both, .speaker))
        XCTAssertFalse(accept(.text, .speaker))
        XCTAssertFalse(accept(.text, .speaker, armed: true), "内蔵スピーカーでは読むを押しても鳴らさない")
        XCTAssertFalse(accept(.text, .privateOutput), "読むを押していない音声は TEXT で鳴らさない")
        XCTAssertTrue(accept(.text, .privateOutput, armed: true))
        XCTAssertFalse(accept(.voice, .speaker, full: true))
        XCTAssertFalse(accept(.voice, .speaker, proto2: false))
        XCTAssertFalse(BlindAudioGate.capsAudio(fullConversationRunning: true))
        XCTAssertTrue(BlindAudioGate.capsAudio(fullConversationRunning: false))
    }

    func testAudioFrameValidation() {
        let header = BlindAudioHeader(id: "ab-12", kind: "speech", bytes: 4, rid: nil)
        XCTAssertTrue(BlindAudioFrame.isValid(header: header, data: Data([0, 1, 2, 3])))
        XCTAssertFalse(BlindAudioFrame.isValid(header: header, data: Data([0, 1, 2])), "大きさがヘッダと合わない")
        XCTAssertFalse(BlindAudioFrame.isValid(header: header, data: Data([0, 1, 2, 3]), maxBytes: 3), "上限超え")
        for bad in ["../x", "a/b", "a b", "", "あ", String(repeating: "a", count: 65)] {
            XCTAssertFalse(BlindAudioFrame.isSafeID(bad), bad)
        }
        XCTAssertTrue(BlindAudioFrame.isSafeID("0aF-z9"))
        XCTAssertGreaterThan(BlindAudioFrame.maxBytes, 1_048_576, "URLSession 既定の 1 MiB より大きい")
    }

    func testReplyWaitKeepsAwakeFromSendUntilReplyPlusGrace() {
        var wait = BlindReplyWait()
        XCTAssertFalse(wait.keepAwake(now: 100))
        wait.noteSent(now: 100)
        XCTAssertTrue(wait.keepAwake(now: 500))
        XCTAssertFalse(wait.keepAwake(now: 100 + BlindReplyWait.maxWait + 1), "返事が来なくても待ち上限で解く")
        wait.noteReply(now: 600)
        XCTAssertTrue(wait.keepAwake(now: 659))
        XCTAssertFalse(wait.keepAwake(now: 661))
        wait.noteSent(now: 700)
        wait.reset()
        XCTAssertFalse(wait.keepAwake(now: 701))
    }

    func testForegroundActionPolicy() {
        XCTAssertEqual(BlindLink.foregroundAction(state: .idle), .none)
        XCTAssertEqual(BlindLink.foregroundAction(state: .reconnecting), .reconnectNow)
        XCTAssertEqual(BlindLink.foregroundAction(state: .connecting), .reconnectNow)
        XCTAssertEqual(BlindLink.foregroundAction(state: .open), .probe)
    }

    // MARK: メッセージの読み取り

    func testParseReadyWithAndWithoutProto() {
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"ready","proto":2,"epoch":"abc"}"#), .ready(proto: 2, epoch: "abc"))
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"ready"}"#), .ready(proto: nil, epoch: nil))
    }

    func testParseReply() {
        let text = #"{"type":"reply","rid":7,"epoch":"e","text":"やあ","question":true,"at":123.5,"origin":"claude_tab","replay":true,"audio":"none","why":"text"}"#
        guard case .reply(let reply)? = BlindServerMessage.parse(text) else { return XCTFail("reply が読めない") }
        XCTAssertEqual(reply.rid, 7)
        XCTAssertEqual(reply.epoch, "e")
        XCTAssertEqual(reply.text, "やあ")
        XCTAssertTrue(reply.question)
        XCTAssertEqual(reply.at, 123.5)
        XCTAssertEqual(reply.origin, "claude_tab")
        XCTAssertTrue(reply.replay)
        XCTAssertEqual(reply.audio, .muted)
        XCTAssertEqual(reply.why, "text")
        guard case .reply(let send)? = BlindServerMessage.parse(#"{"type":"reply","rid":1,"epoch":"e","text":"x","audio":"send"}"#) else {
            return XCTFail("send が読めない")
        }
        XCTAssertEqual(send.audio, .send)
        XCTAssertFalse(send.replay)
    }

    func testParseReplyIgnoresWrongTypes() {
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"reply","epoch":"e","text":"x"}"#))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"reply","rid":"1","epoch":"e","text":"x"}"#))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"reply","rid":true,"epoch":"e","text":"x"}"#))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"reply","rid":1,"epoch":3,"text":"x"}"#))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"reply","rid":1,"epoch":"e","text":5}"#))
    }

    func testParseHeldPathOutputBeepAudio() {
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"held","count":3}"#), .held(3))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"held","count":"3"}"#))
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"path","ok":true,"busy":false,"audio_owner":"blind"}"#),
                       .path(ok: true, busy: false, audioOwner: "blind", name: nil))
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"path","ok":false,"busy":true,"audio_owner":"none","name":"converse"}"#),
                       .path(ok: false, busy: true, audioOwner: "none", name: "converse"))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"path","ok":"yes","busy":false}"#))
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"output","mode":"both"}"#), .output(.both))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"output","mode":"loud"}"#))
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"beep","name":"read_denied"}"#), .beep(.readDenied))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"beep","name":"future_sound"}"#))
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"audio","id":"a1","kind":"done","format":"wav","bytes":44,"rid":9}"#),
                       .audio(BlindAudioHeader(id: "a1", kind: "done", bytes: 44, rid: 9)))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"audio","kind":"done"}"#))
    }

    func testParseKeepsLegacyMessagesAndIgnoresUnknown() {
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"listener","on":true}"#), .listener(true))
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"state","blind_on":true,"mode":"kana"}"#), .state(blindOn: true, mode: "kana"))
        XCTAssertEqual(BlindServerMessage.parse(#"{"type":"config_ok","count":2}"#), .configOK(2))
        XCTAssertNil(BlindServerMessage.parse(#"{"type":"mystery"}"#))
        XCTAssertNil(BlindServerMessage.parse("not json"))
        XCTAssertNil(BlindServerMessage.parse(#"{"no":"type"}"#))
    }

    func testHelloJSONCarriesCapsOutputRouteAndLast() throws {
        let hello = BlindHelloState(device: "dev-1", audio: false, output: .text, route: .privateOutput,
                                    lastEpoch: "e9", lastRid: 12)
        let text = try XCTUnwrap(hello.jsonText())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "hello")
        XCTAssertEqual(object["proto"] as? Int, 2)
        XCTAssertEqual(object["device"] as? String, "dev-1")
        XCTAssertEqual(object["output"] as? String, "text")
        XCTAssertEqual(object["route"] as? String, "private")
        let caps = try XCTUnwrap(object["caps"] as? [String: Any])
        XCTAssertEqual(caps["audio"] as? Bool, false)
        XCTAssertEqual(caps["haptic"] as? Bool, true)
        let last = try XCTUnwrap(object["last"] as? [String: Any])
        XCTAssertEqual(last["epoch"] as? String, "e9")
        XCTAssertEqual(last["rid"] as? Int, 12)
    }

    func testNewActionAndBeepAreDeclared() {
        XCTAssertEqual(BlindAction.output.rawValue, "output")
        XCTAssertTrue(BlindAction.allCases.contains(.output))
        XCTAssertEqual(BlindBeep.readDenied.rawValue, "read_denied")
        XCTAssertFalse(BlindBeep.readDenied.tones.isEmpty)
    }
}

/// 返事・音声の扱い(注入した偽物で、TEXT で音声が一度も始まらないことなどを数える)。
@MainActor
final class BlindSplitCoordinatorTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let suiteName = "blind.split.test.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: BlindReplyStore
        let haptics = RecordingBlindHaptics()
        let audio = RecordingBlindReplyAudio()
        var mode = BlindOutputMode.text
        var route = BlindRoute.speaker
        var full = false
        var claudeFront = false
        var bothHaptics = false
        var proto2 = true
        var readArmed = false
        var now: Double = 1_100
        var played: [String] = []
        var coordinator: BlindReplyCoordinator!

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            store = BlindReplyStore(defaults: defaults)
            let probes = BlindReplyCoordinator.Probes(
                sendPlayed: { [unowned self] id in self.played.append(id) },
                now: { [unowned self] in self.now },
                mode: { [unowned self] in self.mode },
                route: { [unowned self] in self.route },
                fullConversationRunning: { [unowned self] in self.full },
                claudeTabFrontmostAndActive: { [unowned self] in self.claudeFront },
                bothHaptics: { [unowned self] in self.bothHaptics },
                proto2: { [unowned self] in self.proto2 },
                readArmed: { [unowned self] in self.readArmed },
                disarmRead: { [unowned self] in self.readArmed = false }
            )
            coordinator = BlindReplyCoordinator(
                store: store, haptics: haptics, audio: audio, probes: probes,
                directory: FileManager.default.temporaryDirectory
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func header(_ id: String, kind: String = "speech") -> BlindAudioHeader {
        BlindAudioHeader(id: id, kind: kind, bytes: 4, rid: nil)
    }

    func testTextModeNeverStartsAudio() {
        let f = Fixture()
        defer { f.cleanUp() }
        XCTAssertEqual(f.coordinator.handle(reply: makeReply(rid: 1)), .shown)
        XCTAssertEqual(f.coordinator.handle(reply: makeReply(rid: 2, question: true)), .shown)
        f.coordinator.handleAudio(header: header("a1"), data: Data([0, 1, 2, 3]))
        f.coordinator.handleAudio(header: header("a2"), data: Data([0, 1, 2, 3]))
        XCTAssertEqual(f.audio.startCount, 0, "TEXT では音声(AVAudioSession)を始めない")
        XCTAssertTrue(f.audio.enqueued.isEmpty)
        // 捨てた音声も played を返して、サーバーを待たせない
        XCTAssertEqual(f.played, ["a1", "a2"])
        XCTAssertEqual(f.haptics.played, [.reply, .replyQuestion])
    }

    func testVoiceModeStartsAudioLazilyOnFirstAcceptedFrame() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.mode = .voice
        f.coordinator.handle(reply: makeReply(rid: 1))
        XCTAssertEqual(f.audio.startCount, 0, "返事の文字だけでは始めない")
        XCTAssertTrue(f.haptics.played.isEmpty)
        f.coordinator.handleAudio(header: header("a1"), data: Data([0, 1, 2, 3]))
        f.coordinator.handleAudio(header: header("a2"), data: Data([0, 1, 2, 3]))
        XCTAssertEqual(f.audio.startCount, 1)
        XCTAssertEqual(f.audio.enqueued, ["a1", "a2"])
        XCTAssertEqual(f.played, ["a1", "a2"])  // 再生が終わるたびに played
    }

    func testTextWithPrivateRouteAllowsExplicitRead() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.route = .privateOutput
        f.readArmed = true
        f.coordinator.handleAudio(header: header("r1"), data: Data([0, 1, 2, 3]))
        XCTAssertEqual(f.audio.startCount, 1)
        XCTAssertEqual(f.audio.enqueued, ["r1"])
    }

    func testSwitchingToTextStopsAudio() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.mode = .voice
        f.coordinator.handleAudio(header: header("a1"), data: Data([0, 1, 2, 3]))
        XCTAssertTrue(f.audio.isStarted)
        f.mode = .text
        f.coordinator.modeChanged(to: .text)
        XCTAssertFalse(f.audio.isStarted)
        XCTAssertEqual(f.audio.stopCount, 1)
    }

    func testFullConversationRunningDropsAudio() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.mode = .voice
        f.full = true
        f.coordinator.handleAudio(header: header("a1"), data: Data([0, 1, 2, 3]))
        XCTAssertEqual(f.audio.startCount, 0)
        XCTAssertEqual(f.played, ["a1"])
    }

    func testDuplicateReplyIsShownOnceAndVibratesOnce() {
        let f = Fixture()
        defer { f.cleanUp() }
        XCTAssertEqual(f.coordinator.handle(reply: makeReply(rid: 3)), .shown)
        XCTAssertEqual(f.coordinator.handle(reply: makeReply(rid: 3)), .duplicate)
        XCTAssertEqual(f.coordinator.handle(reply: makeReply(rid: 2)), .duplicate)
        XCTAssertEqual(f.haptics.played.count, 1)
        XCTAssertEqual(f.coordinator.repliesHandled, 1)
        XCTAssertEqual(f.store.last?.rid, 3)
        XCTAssertEqual(f.coordinator.lastMarker.rid, 3)
        XCTAssertEqual(f.coordinator.lastMarker.epoch, "e1")
    }

    func testClaudeTabFrontmostSuppressesHapticButStillStoresReply() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.claudeFront = true
        f.coordinator.handle(reply: makeReply(rid: 1, text: "見える"))
        XCTAssertTrue(f.haptics.played.isEmpty)
        XCTAssertEqual(f.store.last?.text, "見える")
    }

    func testStaleReplayStaysSilentButIsShown() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.now = 1_000 + 7_200
        XCTAssertEqual(f.coordinator.handle(reply: makeReply(rid: 1, at: 1_000, replay: true)), .shown)
        XCTAssertTrue(f.haptics.played.isEmpty)
        XCTAssertEqual(f.store.last?.rid, 1)
    }

    func testTextPrivateRouteWithoutReadPressDoesNotPlay() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.route = .privateOutput
        f.coordinator.handleAudio(header: header("n1"), data: Data([0, 1, 2, 3]))
        XCTAssertEqual(f.audio.startCount, 0, "読むを押していない音声は、private でも TEXT では鳴らさない")
        XCTAssertTrue(f.audio.enqueued.isEmpty)
        XCTAssertEqual(f.played, ["n1"])
    }

    func testReadPressIsOneShotEndingAtDoneFrame() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.route = .privateOutput
        f.readArmed = true
        f.coordinator.handleAudio(header: header("s1"), data: Data([0, 1, 2, 3]))
        XCTAssertTrue(f.readArmed, "本体のフレームではまだ消えない")
        f.coordinator.handleAudio(header: header("d1", kind: "done"), data: Data([0, 1, 2, 3]))
        XCTAssertFalse(f.readArmed, "done を鳴らしたら押した記録を消す")
        f.coordinator.handleAudio(header: header("x1"), data: Data([0, 1, 2, 3]))
        XCTAssertEqual(f.audio.enqueued, ["s1", "d1"])
    }

    func testBadFramesAreRejectedWithPlayed() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.mode = .voice
        f.coordinator.handleAudio(header: header("m1"), data: Data([0, 1]))  // 大きさがヘッダと違う
        f.coordinator.handleAudio(header: header("../evil"), data: Data([0, 1, 2, 3]))
        XCTAssertEqual(f.audio.startCount, 0)
        XCTAssertEqual(f.played, ["m1", "../evil"])
    }

    func testReplayBatchBuzzesOncePerConnection() {
        let f = Fixture()
        defer { f.cleanUp() }
        for rid in 1...3 {
            f.coordinator.handle(reply: makeReply(rid: rid, at: 1_000, replay: true))
        }
        XCTAssertEqual(f.haptics.played, [.reply], "再送の 3 件で震えるのは 1 回")
        f.coordinator.handle(reply: makeReply(rid: 4, at: 1_000, replay: false))
        XCTAssertEqual(f.haptics.played.count, 2, "通常の返事は別に震える")
        f.coordinator.beginConnection()
        f.coordinator.handle(reply: makeReply(rid: 5, at: 1_000, replay: true))
        f.coordinator.handle(reply: makeReply(rid: 6, at: 1_000, replay: true))
        XCTAssertEqual(f.haptics.played.count, 3, "再接続のまとまりごとに 1 回")
    }

    func testStopAudioFlushesPendingAndSendsPlayed() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.audio.autoFinish = false
        f.mode = .voice
        f.coordinator.handleAudio(header: header("p1"), data: Data([0, 1, 2, 3]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blind-p1.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(f.played.isEmpty)
        f.mode = .text
        f.coordinator.modeChanged(to: .text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "再生待ちの wav を消す")
        XCTAssertEqual(f.played, ["p1"], "止めた分も played を返す")
    }

    // MARK: 保存・未読

    func testStoreRoundTripAndUnread() throws {
        let name = "blind.split.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BlindReplyStore(defaults: defaults)
        XCTAssertNil(store.last)
        store.register(makeReply(rid: 1, text: "一つ目"))
        store.register(makeReply(rid: 2, text: "二つ目"))
        store.register(makeReply(rid: 3, text: "三つ目"))
        XCTAssertEqual(store.last?.text, "三つ目")
        XCTAssertEqual(store.unread, 3)
        XCTAssertEqual(store.replacedUnread, 2)
        store.markSeen()
        XCTAssertEqual(store.unread, 0)
        XCTAssertEqual(store.replacedUnread, 0)

        // アプリ再起動後もカードに出せ、重複排除の起点にもなる
        let restored = BlindReplyStore(defaults: defaults)
        XCTAssertEqual(restored.last?.text, "三つ目")
        var deduper = restored.makeDeduper()
        XCTAssertFalse(deduper.accept(epoch: "e1", rid: 3))
        XCTAssertTrue(deduper.accept(epoch: "e1", rid: 4))
    }

    // MARK: 合図の出口

    func testTextCuesUseHapticsOnlyAndNeverCreateTonePlayer() {
        let haptics = RecordingBlindHaptics()
        var created = 0
        let factory = BlindCueFactory(haptics: haptics) {
            created += 1
            return RecordingCueOutput()
        }
        factory.router(for: .text).play(.sent)
        factory.router(for: .text).play(.error)
        factory.playModeCue(for: .text)
        XCTAssertEqual(created, 0)
        XCTAssertEqual(factory.tonePlayersCreated, 0)
        XCTAssertEqual(haptics.played, [.sent, .error, .modeText])
    }

    func testVoiceAndBothCuesCreateTonePlayerOnce() {
        let haptics = RecordingBlindHaptics()
        let tone = RecordingCueOutput()
        let factory = BlindCueFactory(haptics: haptics) { tone }
        factory.router(for: .voice).play(.sent)
        XCTAssertEqual(tone.played, [.sent])
        XCTAssertTrue(haptics.played.isEmpty)
        factory.router(for: .both).play(.enter)
        XCTAssertEqual(tone.played, [.sent, .enter])
        XCTAssertEqual(haptics.played, [.enter])
        XCTAssertEqual(factory.tonePlayersCreated, 1)
        factory.playModeCue(for: .both)
        XCTAssertEqual(haptics.played.last, .modeBoth)
    }

    // MARK: ホスト(接続はしない)

    private final class Clock {
        var t: Double = 1_100
    }

    private final class IdleLog {
        var values: [Bool] = []
    }

    private func makeHost(
        haptics: RecordingBlindHaptics, audio: RecordingBlindReplyAudio, suite: String,
        tone: RecordingCueOutput = RecordingCueOutput(), clock: Clock = Clock(),
        appActive: Bool = true, idle: IdleLog = IdleLog(), isMock: Bool = false
    ) -> BlindLinkHost {
        let defaults = UserDefaults(suiteName: suite)!
        return BlindLinkHost(dependencies: BlindLinkHost.Dependencies(
            defaults: defaults,
            haptics: haptics,
            audio: audio,
            routeSource: FixedBlindRouteSource(.speaker),
            makeTonePlayer: { tone },
            fullConversationRunning: { false },
            conversationChanges: Empty<Void, Never>().eraseToAnyPublisher(),
            isMock: isMock,
            now: { clock.t },
            device: "test-device",
            appActive: { appActive },
            setIdleTimerDisabled: { idle.values.append($0) }
        ))
    }

    func testHostOldServerFallsBackAndDisablesTextChip() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let host = makeHost(haptics: RecordingBlindHaptics(), audio: RecordingBlindReplyAudio(), suite: suite)
        XCTAssertTrue(host.textChipEnabled, "proto が分かるまでは無効にしない")
        host.link.onReady?(nil, nil)  // ready に proto が無い = 古いサーバー
        XCTAssertEqual(host.proto, 1)
        XCTAssertFalse(host.textChipEnabled)
        XCTAssertNotNil(host.textChipReason)
        host.setMode(.text)
        XCTAssertEqual(host.mode, .voice, "古いサーバーでは TEXT にしない")
        XCTAssertEqual(host.effectiveMode, .voice)
        host.link.onReady?(2, "e1")
        XCTAssertEqual(host.proto, 2)
        XCTAssertTrue(host.textChipEnabled)
        host.setMode(.text)
        XCTAssertEqual(host.mode, .text)
        XCTAssertEqual(BlindOutputModeStore(defaults: UserDefaults(suiteName: suite)!).load(), .text)
    }

    func testHostReplyHapticAudioAndReadDeniedInTextMode() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let haptics = RecordingBlindHaptics()
        let audio = RecordingBlindReplyAudio()
        let host = makeHost(haptics: haptics, audio: audio, suite: suite)
        host.link.onReady?(2, "e1")
        host.setMode(.text)
        host.link.onReply?(makeReply(rid: 1))
        host.link.onReply?(makeReply(rid: 1))  // 同じ rid は 1 回だけ
        XCTAssertEqual(haptics.played, [.reply])
        host.link.onBeep?(.readDenied)
        XCTAssertEqual(haptics.played, [.reply, .cannotRead])
        host.link.onBeep?(.sent)  // TEXT の合図は振動
        XCTAssertEqual(haptics.played.last, .sent)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertEqual(host.debugTonePlayers, 0)
        XCTAssertEqual(host.replyStore.last?.rid, 1)
    }

    func testHostClaudeTabProbeSuppressesHaptic() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let haptics = RecordingBlindHaptics()
        let host = makeHost(haptics: haptics, audio: RecordingBlindReplyAudio(), suite: suite)
        host.link.onReady?(2, "e1")
        host.setMode(.text)
        host.setClaudeTabProbe { true }
        host.link.onReply?(makeReply(rid: 1))
        XCTAssertTrue(haptics.played.isEmpty)
        host.setClaudeTabProbe { false }
        host.link.onReply?(makeReply(rid: 2))
        XCTAssertEqual(haptics.played, [.reply])
    }

    func testHostServerOutputChangeCuesWithoutSoundInText() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let haptics = RecordingBlindHaptics()
        let host = makeHost(haptics: haptics, audio: RecordingBlindReplyAudio(), suite: suite)
        host.link.onReady?(2, "e1")
        host.link.onOutput?(.voice)  // 同じ値: 何もしない
        XCTAssertTrue(haptics.played.isEmpty)
        host.link.onOutput?(.text)  // キー(F11)での切り替え
        XCTAssertEqual(host.mode, .text)
        XCTAssertEqual(haptics.played, [.modeText])
        XCTAssertEqual(host.debugTonePlayers, 0, "TEXT に入る瞬間は音を鳴らさない(合図音のプレーヤーも作らない)")
    }

    func testHostVoiceToTextStopsToneSessionAndEngine() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let tone = RecordingCueOutput()
        let host = makeHost(haptics: RecordingBlindHaptics(), audio: RecordingBlindReplyAudio(), suite: suite, tone: tone)
        host.link.onReady?(2, "e1")
        host.link.onBeep?(.sent)  // VOICE: 合図音のプレーヤーができて鳴る
        XCTAssertEqual(tone.played, [.sent])
        XCTAssertEqual(host.debugTonePlayers, 1)
        XCTAssertEqual(tone.stopCount, 0)
        host.setMode(.text)
        XCTAssertEqual(tone.stopCount, 1, "TEXT へ切り替えたら、合図音のエンジンとセッションを手放す")
        host.link.onBeep?(.sent)
        XCTAssertEqual(tone.played, [.sent], "TEXT では合図音を鳴らさない")
    }

    func testHostDisableStopsTone() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let tone = RecordingCueOutput()
        let host = makeHost(haptics: RecordingBlindHaptics(), audio: RecordingBlindReplyAudio(), suite: suite,
                            tone: tone, isMock: true)
        host.enable()
        host.link.onBeep?(.sent)
        host.disable()
        XCTAssertEqual(tone.stopCount, 1)
        XCTAssertFalse(host.enabled)
    }

    func testHostFutureProtoIsNotTreatedAsLegacy() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let host = makeHost(haptics: RecordingBlindHaptics(), audio: RecordingBlindReplyAudio(), suite: suite)
        host.link.onReady?(3, "e1")
        XCTAssertTrue(host.isProto2)
        XCTAssertTrue(host.textChipEnabled)
    }

    func testHostChipIgnoresStaleServerEcho() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let haptics = RecordingBlindHaptics()
        let clock = Clock()
        let host = makeHost(haptics: haptics, audio: RecordingBlindReplyAudio(), suite: suite, clock: clock)
        host.link.onReady?(2, "e1")
        host.setMode(.text)
        host.link.onOutput?(.voice)  // 古い値のエコー
        XCTAssertEqual(host.mode, .text, "チップが戻らない")
        XCTAssertTrue(haptics.played.isEmpty, "余分な合図も鳴らない")
        host.link.onOutput?(.text)  // 待っていた値のエコー: 保留が解ける
        XCTAssertTrue(haptics.played.isEmpty)
        host.link.onOutput?(.both)  // 以後は別経路(キー)の切り替えとして受ける
        XCTAssertEqual(host.mode, .both)
        XCTAssertEqual(haptics.played, [.modeBoth])
        // 保留が期限切れなら、そのまま受ける
        host.setMode(.voice)
        clock.t += 10
        host.link.onOutput?(.text)
        XCTAssertEqual(host.mode, .text)
    }

    func testHostDisconnectNoticeSuppressedInBackgroundAndOnClaudeTab() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let haptics = RecordingBlindHaptics()
        let inactive = makeHost(haptics: haptics, audio: RecordingBlindReplyAudio(), suite: suite, appActive: false)
        inactive.link.onReady?(2, "e1")
        inactive.setMode(.text)
        inactive.link.onDisconnected?()
        XCTAssertTrue(haptics.played.isEmpty, "背面では告知しない")

        let active = makeHost(haptics: haptics, audio: RecordingBlindReplyAudio(), suite: suite, appActive: true)
        active.link.onReady?(2, "e1")
        active.setClaudeTabProbe { true }
        active.link.onDisconnected?()
        XCTAssertTrue(haptics.played.isEmpty, "Claude タブが前面なら告知しない")
        active.setClaudeTabProbe { false }
        active.link.onDisconnected?()
        XCTAssertEqual(haptics.played, [.error])
    }

    func testHostReadKeyArmsThenExpires() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let host = makeHost(haptics: RecordingBlindHaptics(), audio: RecordingBlindReplyAudio(), suite: suite, clock: clock)
        XCTAssertFalse(host.isReadArmed)
        host.push(BlindKeyEvent(hid: 4, down: true, t: 0, char: "a"))
        XCTAssertFalse(host.isReadArmed, "ふつうのキーでは立たない")
        host.push(BlindKeyEvent(hid: 43, down: true, t: 1, char: nil))  // Tab(既定の読む)
        XCTAssertTrue(host.isReadArmed)
        clock.t += BlindLinkHost.readArmSeconds + 1
        XCTAssertFalse(host.isReadArmed, "期限が切れる")
        host.assign(BlindBinding(action: .read, hid: 99, style: .tap))
        host.push(BlindKeyEvent(hid: 99, down: false, t: 2, char: nil))
        XCTAssertFalse(host.isReadArmed, "離すだけでは立たない")
        host.push(BlindKeyEvent(hid: 99, down: true, t: 3, char: nil))
        XCTAssertTrue(host.isReadArmed, "本人が割り当てた read のキーでも立つ")
    }

    func testHostKeepsScreenAwakeWhileWaitingForReplyInText() {
        let suite = "blind.split.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let idle = IdleLog()
        let host = makeHost(haptics: RecordingBlindHaptics(), audio: RecordingBlindReplyAudio(), suite: suite,
                            clock: clock, idle: idle)
        host.link.onReady?(2, "e1")
        host.link.onBeep?(.sent)  // VOICE では何もしない
        XCTAssertFalse(host.replyWaitWantsAwake)
        host.setMode(.text)
        host.link.onBeep?(.sent)
        XCTAssertTrue(host.replyWaitWantsAwake)
        XCTAssertEqual(idle.values.last, true)
        host.link.onReply?(makeReply(rid: 1, at: clock.t))
        clock.t += 59
        XCTAssertTrue(host.replyWaitWantsAwake)
        clock.t += 2
        host.refreshIdleTimer()
        XCTAssertFalse(host.replyWaitWantsAwake)
        XCTAssertEqual(idle.values.last, false)
        host.setScreenWantsAwake(true)
        XCTAssertEqual(idle.values.last, true, "画面が見えている間の希望はそのまま通る")
    }
}

/// BlindLink 自体(proto の判別・hello の順序・音声のヘッダとバイナリの対・大きさの検査)。WebSocket は使わず、送る文字列を溜める。
@MainActor
final class BlindSplitLinkTests: XCTestCase {
    private final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        func types() -> [String] {
            all.compactMap { text in
                (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String
            }
        }
    }

    private func makeLink(withBinding: Bool, suite: String) -> (BlindLink, Outbox) {
        let defaults = UserDefaults(suiteName: suite)!
        let store = BlindBindingsStore(defaults: defaults)
        if withBinding {
            var b = BlindBindings()
            b.set(BlindBinding(action: .toggle, hid: 228, style: .double))
            store.save(b)
        }
        let link = BlindLink(store: store)
        let outbox = Outbox()
        link.useTestOutbox { outbox.add($0) }
        link.setHello(BlindHelloState(device: "d", audio: true, output: .text, route: .speaker, lastEpoch: "e", lastRid: 4))
        return (link, outbox)
    }

    private func settle(_ link: BlindLink) {
        link.drainForTesting()
        link.drainForTesting()
    }

    func testHelloIsSentBeforeConfigOnProto2() {
        let suite = "blind.split.link.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (link, outbox) = makeLink(withBinding: true, suite: suite)
        link.ingestForTesting(#"{"type":"ready","proto":2,"epoch":"e"}"#)
        settle(link)
        XCTAssertEqual(outbox.types(), ["hello", "config"], "hello を config より先に宣言する")
    }

    func testNoHelloOnLegacyReady() {
        let suite = "blind.split.link.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (link, outbox) = makeLink(withBinding: true, suite: suite)
        link.ingestForTesting(#"{"type":"ready"}"#)
        settle(link)
        XCTAssertEqual(outbox.types(), ["config"], "proto の無い ready には hello を送らない")
        link.sendCaps(audio: false)
        link.sendRoute(.privateOutput)
        settle(link)
        XCTAssertEqual(outbox.types(), ["config"], "旧サーバーには proto 2 のメッセージを送らない")
    }

    func testFutureProtoStillGetsHello() {
        let suite = "blind.split.link.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (link, outbox) = makeLink(withBinding: false, suite: suite)
        link.ingestForTesting(#"{"type":"ready","proto":3,"epoch":"e"}"#)
        settle(link)
        XCTAssertEqual(outbox.types(), ["hello"])
    }

    func testAudioHeaderPairsWithNextBinary() async {
        let suite = "blind.split.link.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (link, outbox) = makeLink(withBinding: false, suite: suite)
        let got = expectation(description: "audio")
        var received: (BlindAudioHeader, Data)?
        link.onAudio = { header, data in
            received = (header, data)
            got.fulfill()
        }
        link.ingestForTesting(#"{"type":"ready","proto":2,"epoch":"e"}"#)
        link.ingestForTesting(#"{"type":"audio","id":"a1","kind":"speech","format":"wav","bytes":4,"rid":3}"#)
        link.ingestBinaryForTesting(Data([9, 8, 7, 6]))
        await fulfillment(of: [got], timeout: 5)
        XCTAssertEqual(received?.0, BlindAudioHeader(id: "a1", kind: "speech", bytes: 4, rid: 3))
        XCTAssertEqual(received?.1, Data([9, 8, 7, 6]))
        settle(link)
        XCTAssertFalse(outbox.types().contains("played"), "正しい対は link では played を返さない(再生後に host が返す)")
    }

    func testBinaryWithoutHeaderIsIgnored() async throws {
        let suite = "blind.split.link.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (link, _) = makeLink(withBinding: false, suite: suite)
        var called = false
        link.onAudio = { _, _ in called = true }
        link.ingestForTesting(#"{"type":"ready","proto":2,"epoch":"e"}"#)
        link.ingestBinaryForTesting(Data([1, 2, 3]))
        settle(link)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(called)
    }

    func testSizeMismatchFrameIsRejectedWithPlayed() async throws {
        let suite = "blind.split.link.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (link, outbox) = makeLink(withBinding: false, suite: suite)
        var called = false
        link.onAudio = { _, _ in called = true }
        link.ingestForTesting(#"{"type":"ready","proto":2,"epoch":"e"}"#)
        link.ingestForTesting(#"{"type":"audio","id":"big1","kind":"speech","format":"wav","bytes":8}"#)
        link.ingestBinaryForTesting(Data([1, 2, 3, 4]))
        settle(link)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(called)
        XCTAssertTrue(outbox.all.contains { $0.contains("\"played\"") && $0.contains("big1") })
    }

    func testReplacedAudioHeaderGetsPlayedForTheOldId() {
        let suite = "blind.split.link.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (link, outbox) = makeLink(withBinding: false, suite: suite)
        link.ingestForTesting(#"{"type":"ready","proto":2,"epoch":"e"}"#)
        link.ingestForTesting(#"{"type":"audio","id":"first","kind":"speech","format":"wav","bytes":4}"#)
        link.ingestForTesting(#"{"type":"audio","id":"second","kind":"speech","format":"wav","bytes":4}"#)
        settle(link)
        XCTAssertTrue(outbox.all.contains { $0.contains("\"played\"") && $0.contains("first") })
        XCTAssertFalse(outbox.all.contains { $0.contains("\"played\"") && $0.contains("second") })
    }
}
