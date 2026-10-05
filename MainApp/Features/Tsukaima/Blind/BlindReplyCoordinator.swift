import Foundation

/// 返事 1 件・音声フレーム 1 本の扱いを決める(UIKit / AVFoundation を直接は使わない。すべて注入)。
/// - 重複(epoch/rid)の排除 → 最新 1 件の保存 → 振動の判断。
/// - 音声は規則(BlindAudioGate)を通ったものだけ、最初の 1 本で初めて audio.start() を呼ぶ(TEXT では呼ばない)。
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

    init(store: BlindReplyStore, haptics: any BlindHaptics, audio: any BlindReplyAudio, probes: Probes,
         directory: URL = FileManager.default.temporaryDirectory) {
        self.store = store
        self.deduper = store.makeDeduper()
        self.haptics = haptics
        self.audio = audio
        self.probes = probes
        self.directory = directory
        audio.onFinished = { [probes] id in probes.sendPlayed(id) }
    }

    /// hello の last に載せる、受け取り済みの最後の epoch/rid。
    var lastMarker: (epoch: String, rid: Int) {
        (deduper.lastEpoch ?? "", deduper.lastRid)
    }

    @discardableResult
    func handle(reply: BlindReply) -> Outcome {
        guard deduper.accept(epoch: reply.epoch, rid: reply.rid) else { return .duplicate }
        repliesHandled += 1
        store.register(reply)
        let pattern = BlindHapticDecision.replyPattern(
            reply: reply,
            mode: probes.mode(),
            bothHaptics: probes.bothHaptics(),
            claudeTabFrontmostAndActive: probes.claudeTabFrontmostAndActive(),
            now: probes.now()
        )
        if let pattern { haptics.play(pattern) }
        return .shown
    }

    func handleAudio(header: BlindAudioHeader, data: Data) {
        let allowed = BlindAudioGate.accept(
            proto2: probes.proto2(),
            mode: probes.mode(),
            route: probes.route(),
            fullConversationRunning: probes.fullConversationRunning()
        )
        guard allowed else {
            probes.sendPlayed(header.id)  // 捨てる音声も played を返して、サーバーを待たせない
            return
        }
        do {
            try audio.start()
            let url = directory.appendingPathComponent("blind-\(header.id).wav")
            try data.write(to: url, options: .atomic)
            audio.enqueue(id: header.id, url: url)
        } catch {
            probes.sendPlayed(header.id)
            onAudioError?("返事の音を再生できません")
        }
    }

    /// 出し方が変わったとき。TEXT になったら音声を手放す(次の音声で初めて VOICE/BOTH が再開する)。
    func modeChanged(to mode: BlindOutputMode) {
        if mode == .text { audio.stop() }
    }

    /// 接続をやめるとき・設定を閉じるとき。
    func stopAudio() {
        audio.stop()
    }
}
