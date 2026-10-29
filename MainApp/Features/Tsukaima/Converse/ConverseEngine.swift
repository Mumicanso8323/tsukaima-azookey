import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 会話モード本体(docs/voice-coding-design.md・docs/converse-protocol.md)。
/// ConverseAudioIO(マイク+再生)と ConverseLink(/ws/converse)を配線する。
/// App Intents(ConverseIntents.swift)と画面(ConverseStatusView.swift)の両方から `ConverseEngine.shared` を触る。
/// TsukaimaRecorderEngine と同じ形: main スレッド専用(呼び出し側で保証)、コールバックは
/// ConverseAudioIO/ConverseLink 側ですでに main へ戻してあるので、ここではそのまま @Published に反映するだけ。
/// REQ-0: 会話中は画面を見ない・触らない前提なので、ここで持つ状態は「見なくても困らない」最小限にとどめる。
/// 失敗は必ず耳に届ける(端末側の読み上げ ConverseLocalVoice。規則は ConversePolicies.swift)。
final class ConverseEngine: ObservableObject, @unchecked Sendable {
    enum Phase: Equatable {
        case stopped
        case connecting
        case idle       // サーバー的には「オーバー」待ち
        case accepted
        case working
        case speaking
        case question
        case error(String)
    }

    static let shared = ConverseEngine()

    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var lastReplyText: String?
    @Published private(set) var lastTranscript: String?

    /// true の間は再生専用(ブラインド画面用。マイクなし・音声フレームは送らない)
    @Published private(set) var playbackOnly = false

    private let audio = ConverseAudioIO()
    private let link = ConverseLink()
    private let voice = ConverseLocalVoice()
    private var running = false
    private var ownership = PlaybackOwnership()
    /// A3: つながらない状態が続いたら端末で知らせる
    private var outage = ConverseOutageNotifier()
    private var outageTimer: Timer?
    /// A4: 音声が止まったあとの自動復帰
    private var recovery = ConverseRecoveryPolicy()
    private var recoveryTimer: Timer?
    /// A5: イヤホンが外れて自分で掛けた hold
    private var holdByRoute = ConverseHoldByRoute()
    /// A3: 4403 で回線が止まっている(start() でつなぎ直す)
    private var authFailed = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        audio.onMicChunk = { [link] data in link.pushAudio(data) }
        audio.onError = { [weak self] msg in self?.audioFailed(msg) }
        audio.onPlaybackFinished = { [weak self] id in self?.link.sendPlayed(id: id) }
        audio.onRouteLost = { [weak self] in self?.routeLost() }
        audio.onRouteGained = { [weak self] in self?.routeGained() }
        audio.onRecovered = { [weak self] in self?.audioRecovered() }
        voice.onBusy = { [weak self] on in self?.audio.setDucking(on) }
        link.onLinkState = { [weak self] s in self?.applyLinkState(s) }
        link.onServerState = { [weak self] s in self?.applyServerState(s) }
        link.onTranscript = { [weak self] text, _ in self?.lastTranscript = text }
        link.onReplyText = { [weak self] text in self?.lastReplyText = text }
        link.onAudio = { [weak self] header, data in self?.handleAudio(header, data) }
        link.onSpeechFailed = { [weak self] text, sent in self?.speechFailed(text, sent: sent) }
        link.onNotice = { [weak self] code, say in self?.notice(code, say: say) }
        #if canImport(UIKit)
        // A6(S15): 前面復帰・ロック解除で止まっていれば起こす(ブラインド画面を開いていなくても)
        let nc = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.ensure()
            })
        }
        #endif
    }

    var isRunning: Bool { running }

    /// 会話モードを開始する。講義録音(TsukaimaMic)が動いている間は始めない(音声セッションの取り合いを避ける)。
    func start() throws {
        if running {
            // 認証切れで回線だけ止まっているなら、もう一度つなぎに行く(登録し直したあとの「会話を始める」)
            if case .error = phase, authFailed {
                authFailed = false
                phase = .connecting
                link.connect()
                return
            }
            // 再生専用で動いているなら、マイクありの会話モードへ格上げする(以後ブラインド画面は持ち主ではなくなる)
            if ownership.isPlaybackOnly {
                guard !TsukaimaMic.active else { throw Self.lectureError("講義の録音中は会話モードを始められません") }
                try audio.upgradeToMicrophone()
                ownership.markFull()
                playbackOnly = false
            }
            return
        }
        guard !TsukaimaMic.active else { throw Self.lectureError("講義の録音中は会話モードを始められません") }
        running = true
        phase = .connecting
        lastReplyText = nil
        lastTranscript = nil
        do {
            try audio.start()
        } catch {
            running = false
            phase = .stopped
            throw error
        }
        ownership.markFull()
        playbackOnly = false
        link.connect()
    }

    /// ブラインド画面用。再生専用(マイク・音声送信なし)で /ws/converse をつなぎ、返事を耳に届ける。
    /// すでに会話モードで動いていれば何も変えず false(持ち主ではない)。止まっていて始められたら true(持ち主)。
    func startPlaybackOnly() throws -> Bool {
        guard !running else { return false }
        guard !TsukaimaMic.active else { throw Self.lectureError("返事は聞けません(講義の録音中)") }
        running = true
        phase = .connecting
        lastReplyText = nil
        lastTranscript = nil
        do {
            try audio.start(microphone: false)
        } catch {
            running = false
            phase = .stopped
            throw error
        }
        _ = ownership.beginPlaybackOnly()
        playbackOnly = true
        link.connect()
        return true
    }

    /// 持ち主(startPlaybackOnly が true を返した側)が閉じるとき。途中で会話モードに格上げされていたら止めない。
    func stopIfOwned(_ owned: Bool) {
        guard running, ownership.stopIfOwned(owned) else { return }
        shutdown(sendStop: false)  // 会話は始めていないので stop は送らず、切断だけする
    }

    /// 前面復帰・経路変更のあと、音声が止まっていたら再開する。
    func ensure() {
        guard running else { return }
        audio.ensure()
    }

    func stop() {
        guard running else { return }
        let wasPlaybackOnly = ownership.isPlaybackOnly
        _ = ownership.stop()
        shutdown(sendStop: !wasPlaybackOnly)
    }

    /// 端末側の読み上げで一言(会話モードが動いていなくても鳴らせる。Intent の失敗など。A6・S22)。
    func announce(_ text: String) {
        voice.speak(text)
    }

    private func shutdown(sendStop: Bool) {
        running = false
        playbackOnly = false
        link.disconnect(sendStop: sendStop)
        voice.stop()
        audio.stop()
        stopOutageTimer()
        stopRecoveryTimer()
        holdByRoute.reset()
        authFailed = false
        phase = .stopped
    }

    private static func lectureError(_ text: String) -> NSError {
        NSError(domain: "converse", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func applyServerState(_ s: String) {
        switch s {
        case "idle": phase = .idle
        case "accepted": phase = .accepted
        case "working": phase = .working
        case "speaking": phase = .speaking
        case "question": phase = .question
        default: break
        }
    }

    // MARK: 回線(A3)

    private func applyLinkState(_ s: ConverseLink.LinkState) {
        guard running else { return }
        switch s {
        case .connecting, .reconnecting:
            phase = .connecting
            outage.began(now: ProcessInfo.processInfo.systemUptime)
            startOutageTimer()
        case .open:
            outage.ended()
            stopOutageTimer()
        case .authFailed:
            outage.ended()
            stopOutageTimer()
            authFailed = true
            phase = .error("認証が切れました")
            voice.speak(ConverseLocalPhrase.authExpired)
        case .idle:
            break
        }
    }

    private func startOutageTimer() {
        guard outageTimer == nil else { return }
        outageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            if self.outage.tick(now: ProcessInfo.processInfo.systemUptime) {
                AudioDiag.logWithApp("audio link outage notify")
                self.voice.speak(ConverseOutageNotifier.phrase)
            }
        }
    }

    private func stopOutageTimer() {
        outageTimer?.invalidate()
        outageTimer = nil
    }

    // MARK: 声が作れなかった(A2)

    private func speechFailed(_ text: String, sent: Int) {
        AudioDiag.logWithApp("audio speech_failed sent=\(sent) chars=\(text.count)")
        if let phrase = ConverseLocalPhrase.forSpeechFailed(text: text, sent: sent) { voice.speak(phrase) }
    }

    private func notice(_ code: String, say: String) {
        AudioDiag.logWithApp("audio notice code=\(code)")
        voice.speak(say)
    }

    // MARK: 音声が止まった(A4)

    private func audioFailed(_ msg: String) {
        phase = .error(msg)
        guard running else { return }
        if let delay = recovery.nextDelay() {
            AudioDiag.logWithApp("audio recover schedule attempt=\(recovery.attempts) in=\(Int(delay))s")
            voice.speak(ConverseLocalPhrase.audioStopped)
            stopRecoveryTimer()
            recoveryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self, self.running else { return }
                self.recoveryTimer = nil
                self.audio.recover()
            }
        } else {
            AudioDiag.logWithApp("audio recover gave up")
            voice.speak(ConverseLocalPhrase.audioGaveUp)
            // 読み上げが終わるのを待ってから止める(止めると端末の声も止まる)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.stop() }
        }
    }

    private func audioRecovered() {
        AudioDiag.logWithApp("audio recover ok")
        recovery.recovered()
        if case .error = phase { phase = .idle }  // 本当の状態は次の ping で合わせる
    }

    private func stopRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    // MARK: イヤホンが外れた(A5)

    private func routeLost() {
        guard running, holdByRoute.lost() else { return }
        AudioDiag.logWithApp("audio route lost -> hold")
        setReplyDelivery("hold")
    }

    private func routeGained() {
        guard running else {
            // 動いていないのに hold を自分で掛けたままにしない
            if holdByRoute.gained() { setReplyDelivery("speak") }
            return
        }
        if holdByRoute.gained() {
            AudioDiag.logWithApp("audio route gained -> speak")
            setReplyDelivery("speak")
        }
    }

    /// サーバーの返事の出し方(docs/converse-protocol.md「入力・返事の設定」)。失敗しても会話は続ける。
    private func setReplyDelivery(_ mode: String) {
        Task { @MainActor in
            do {
                _ = try await TsukaimaAPI.shared.sendJSON("POST", "/api/converse/prefs",
                                                          json: ["reply_delivery": mode], signed: true)
            } catch {
                AudioDiag.logWithApp("audio prefs \(mode) failed err=\((error as NSError).domain)#\((error as NSError).code)")
            }
        }
    }

    private func handleAudio(_ header: ConverseLink.AudioHeader, _ data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("converse-\(header.id).\(header.format)")
        do {
            try data.write(to: url, options: .atomic)
            audio.enqueuePlayback(id: header.id, fileURL: url)
        } catch {
            // 書けなかった wav はすぐ played を返して詰まらせない
            link.sendPlayed(id: header.id)
        }
    }
}
