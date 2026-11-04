import Foundation

/// 返事の音声(再生専用)の出口。TEXT のあいだは start() を呼ばない(音声セッションに触れない)ことをテストで数える。
@MainActor
protocol BlindReplyAudio: AnyObject {
    /// start() を呼んだ回数
    var startCount: Int { get }
    var isStarted: Bool { get }
    func start() throws
    func enqueue(id: String, url: URL)
    func stop()
    /// 1 本の再生が終わったとき(main)。id は enqueue した id。
    var onFinished: ((String) -> Void)? { get set }
}

/// 実体: ConverseAudioIO を再生専用(microphone:false)で使う。start でだけ AVAudioSession を取り、stop で手放す。
@MainActor
final class ConverseBlindReplyAudio: BlindReplyAudio {
    private let io = ConverseAudioIO()
    private(set) var startCount = 0
    private(set) var isStarted = false
    var onFinished: ((String) -> Void)?

    init() {
        io.onPlaybackFinished = { [weak self] id in
            // ConverseAudioIO は main で呼ぶ
            MainActor.assumeIsolated { self?.onFinished?(id) }
        }
    }

    func start() throws {
        guard !isStarted else { return }
        // 講義録音(TsukaimaMic)と音声セッションを取り合わない
        guard !TsukaimaMic.active else {
            throw NSError(domain: "converse", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "返事は聞けません(講義の録音中)"])
        }
        startCount += 1
        try io.start(microphone: false)
        isStarted = true
    }

    func enqueue(id: String, url: URL) {
        io.enqueuePlayback(id: id, fileURL: url)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        io.stop()
    }
}

/// 呼び出しを数えるだけの音声(単体テストと UI テストの mock 用)。enqueue した分はすぐ再生済みにする。
@MainActor
final class RecordingBlindReplyAudio: BlindReplyAudio {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// false にすると、再生が終わらないまま溜まる(止めたときの後始末を試せる)
    var autoFinish = true
    private(set) var enqueued: [String] = []
    private(set) var isStarted = false
    var onFinished: ((String) -> Void)?

    func start() throws {
        guard !isStarted else { return }
        startCount += 1
        isStarted = true
    }

    func enqueue(id: String, url: URL) {
        enqueued.append(id)
        if autoFinish { onFinished?(id) }
    }

    func stop() {
        guard isStarted else { return }
        stopCount += 1
        isStarted = false
    }
}

/// 受け取った音声フレームを鳴らしてよいかの規則(サーバーの選出の上に重ねる 2 重の安全)。
enum BlindAudioGate {
    static func accept(proto2: Bool, mode: BlindOutputMode, route: BlindRoute, fullConversationRunning: Bool,
                       readArmed: Bool) -> Bool {
        guard proto2, !fullConversationRunning else { return false }
        switch mode {
        case .voice, .both: return true
        // TEXT は本人が「読む」を押した直後(readArmed)の一度きりの再生だけ。内蔵スピーカーなら捨てる。
        // サーバーは TEXT で TTS を作らないが、サーバーの送ってきた音声を信用せず、押した記録を要求する。
        case .text: return route == .privateOutput && readArmed
        }
    }

    /// 音の持ち主の資格。フルの会話モードが動いている間は名乗らない(AVAudioEngine を 2 つ鳴らさない)。
    static func capsAudio(fullConversationRunning: Bool) -> Bool {
        !fullConversationRunning
    }
}

/// 音声フレーム(ヘッダ+バイナリ)の検査。大きさがヘッダと合わない・上限超え・id に変な文字がある物は鳴らさない。
enum BlindAudioFrame {
    /// WebSocket 1 メッセージの上限(URLSession の既定 1 MiB では約 20 秒の wav で受信が失敗するため引き上げる)。
    static let maxBytes = 8 * 1024 * 1024

    static func isValid(header: BlindAudioHeader, data: Data, maxBytes: Int = BlindAudioFrame.maxBytes) -> Bool {
        data.count == header.bytes && data.count <= maxBytes && isSafeID(header.id)
    }

    /// 一時ファイル名に使うので、英数とハイフンだけ(サーバーの値のまま使わない)。
    static func isSafeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122) || scalar.value == 45
        }
    }
}
