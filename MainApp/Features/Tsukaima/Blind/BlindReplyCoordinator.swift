import Foundation

/// 返事 1 件・音声フレーム 1 本の扱いを決める(UIKit / AVFoundation を直接は使わない。すべて注入)。
/// - 重複(epoch/rid)の排除 → 最新 1 件の保存 → 振動の判断。
/// - 音声は規則(BlindAudioGate)を通ったものだけ、最初の 1 本で初めて audio.start() を呼ぶ(TEXT では「読む」直後以外は呼ばない)。
@MainActor
final class BlindReplyCoordinator {
    struct Probes {
        var sendPlayed: (String) -> Void
        var now: () -> Double
        var mode: () -> BlindOutputMode
        var route: () -> BlindRoute
        var fullConversationRunning: () -> Bool
        var claudeTabFrontmostAndActive: () -> Bool
        var bothHaptics: () -> Bool
        var proto2: () -> Bool
        /// 本人が「読む」を押した直後か(TEXT での再生の条件)
        var readArmed: () -> Bool
        /// 読むの 1 回分が終わった(done/question のフレームを鳴らした)ので、押した記録を消す
        var disarmRead: () -> Void
    }

    enum Outcome: Equatable {
        case shown
        case duplicate
    }

    let store: BlindReplyStore
    private(set) var deduper: BlindReplyDeduper
    private let haptics: any BlindHaptics
    private let audio: any BlindReplyAudio
    private let probes: Probes
    private let directory: URL
    /// 音声を始められなかったときの 1 行(画面に出す)
    var onAudioError: ((String) -> Void)?
    private(set) var repliesHandled = 0
    /// enqueue 済みで、まだ再生が終わっていない wav(id → 一時ファイル)。止めるときに消して played を返す。
    private var pendingFiles: [String: URL] = [:]
    /// 再接続での再送のまとまりに、振動を 1 回だけ出すための印(新しい接続ごとに beginConnection で戻す)。
    private var replayBuzzed = false

    init(store: BlindReplyStore, haptics: any BlindHaptics, audio: any BlindReplyAudio, probes: Probes,
         directory: URL = FileManager.default.temporaryDirectory) {
        self.store = store
        self.deduper = store.makeDeduper()
        self.haptics = haptics
        self.audio = audio
        self.probes = probes
        self.directory = directory
        audio.onFinished = { [weak self] id in self?.finished(id) }
    }

    /// hello の last に載せる、受け取り済みの最後の epoch/rid。
    var lastMarker: (epoch: String, rid: Int) {
        (deduper.lastEpoch ?? "", deduper.lastRid)
    }

    /// 新しい接続の始まり(ready)。再送の振動の「1 回」をここで数え直す。
    func beginConnection() {
        replayBuzzed = false
    }

    @discardableResult
    func handle(reply: BlindReply) -> Outcome {
        guard deduper.accept(epoch: reply.epoch, rid: reply.rid) else { return .duplicate }
        repliesHandled += 1
        store.register(reply)
        var pattern = BlindHapticDecision.replyPattern(
            reply: reply,
            mode: probes.mode(),
            bothHaptics: probes.bothHaptics(),
            claudeTabFrontmostAndActive: probes.claudeTabFrontmostAndActive(),
            now: probes.now()
        )
        if reply.replay {
            // 再送は最大 5 件届く。まとまりごとに 1 回だけ震える(DEC-13/14)。
            if replayBuzzed { pattern = nil } else if pattern != nil { replayBuzzed = true }
        }
        if let pattern { haptics.play(pattern) }
        return .shown
    }

    func handleAudio(header: BlindAudioHeader, data: Data) {
        guard BlindAudioFrame.isValid(header: header, data: data) else {
            probes.sendPlayed(header.id)  // 大きさ違い・変な id は鳴らさず、サーバーを待たせない
            return
        }
        let allowed = BlindAudioGate.accept(
            proto2: probes.proto2(),
            mode: probes.mode(),
            route: probes.route(),
            fullConversationRunning: probes.fullConversationRunning(),
            readArmed: probes.readArmed()
        )
        guard allowed else {
            probes.sendPlayed(header.id)  // 捨てる音声も played を返して、サーバーを待たせない(書き出さないので消す物は無い)
            return
        }
        do {
            try audio.start()
            let url = directory.appendingPathComponent("blind-\(header.id).wav")
            try data.write(to: url, options: .atomic)
            pendingFiles[header.id] = url
            audio.enqueue(id: header.id, url: url)
            // 読むの 1 回分(本体 → done/question)の最後を鳴らしたら、押した記録を消す
            if header.kind == "done" || header.kind == "question" { probes.disarmRead() }
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("blind-\(header.id).wav"))
            pendingFiles[header.id] = nil
            probes.sendPlayed(header.id)
            onAudioError?("返事の音を再生できません")
        }
    }

    private func finished(_ id: String) {
        if let url = pendingFiles.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: url)  // ConverseAudioIO も消すが、無くても困らない
        }
        probes.sendPlayed(id)
    }

    /// 出し方が変わったとき。TEXT になったら音声を手放す(次の音声で初めて VOICE/BOTH が再開する)。
    func modeChanged(to mode: BlindOutputMode) {
        if mode == .text { stopAudio() }
    }

    /// 接続をやめるとき・TEXT へ切り替えるとき。再生待ちの wav を消し、サーバーには played を返す。
    func stopAudio() {
        audio.stop()
        let leftovers = pendingFiles
        pendingFiles = [:]
        for (id, url) in leftovers {
            try? FileManager.default.removeItem(at: url)
            probes.sendPlayed(id)
        }
    }
}
