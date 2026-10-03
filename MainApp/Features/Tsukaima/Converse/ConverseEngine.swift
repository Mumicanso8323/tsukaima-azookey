import AVFoundation
import SwiftUI

/// 会話モード本体(docs/voice-coding-design.md・docs/converse-protocol.md)。
/// ConverseAudioIO(マイク+再生)と ConverseLink(/ws/converse)を配線する。
/// App Intents(ConverseIntents.swift)と画面(ConverseStatusView.swift)の両方から `ConverseEngine.shared` を触る。
/// TsukaimaRecorderEngine と同じ形: main スレッド専用(呼び出し側で保証)、コールバックは
/// ConverseAudioIO/ConverseLink 側ですでに main へ戻してあるので、ここではそのまま @Published に反映するだけ。
/// REQ-0: 会話中は画面を見ない・触らない前提なので、ここで持つ状態は「見なくても困らない」最小限にとどめる。
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

    private let audio = ConverseAudioIO()
    private let link = ConverseLink()
    private var running = false

    private init() {
        audio.onMicChunk = { [link] data in link.pushAudio(data) }
        audio.onError = { [weak self] msg in self?.phase = .error(msg) }
        audio.onPlaybackFinished = { [weak self] id in self?.link.sendPlayed(id: id) }
        link.onLinkState = { [weak self] s in
            guard let self, self.running else { return }
            if s == .connecting || s == .reconnecting { self.phase = .connecting }
        }
        link.onServerState = { [weak self] s in self?.applyServerState(s) }
        link.onTranscript = { [weak self] text, _ in self?.lastTranscript = text }
        link.onReplyText = { [weak self] text in self?.lastReplyText = text }
        link.onAudio = { [weak self] header, data in self?.handleAudio(header, data) }
    }

    var isRunning: Bool { running }

    /// 会話モードを開始する。講義録音(TsukaimaMic)が動いている間は始めない(音声セッションの取り合いを避ける)。
    func start() throws {
        guard !running else { return }
        guard !TsukaimaMic.active else {
            throw NSError(domain: "converse", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "講義の録音中は会話モードを始められません"])
        }
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
        link.connect()
    }

    func stop() {
        guard running else { return }
        running = false
        link.disconnect(sendStop: true)
        audio.stop()
        phase = .stopped
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
