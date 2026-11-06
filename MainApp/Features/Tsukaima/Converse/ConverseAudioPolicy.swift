import Foundation

/// 会話モードの「会話のマイク」設定(設定画面の選択肢)。
/// 11/4 以降、BT イヤホンで経路が A2DP→HFP に切り替わる最中にエンジンが作り直されて文字起こしが 1 件も出なくなった。
/// 既定の「本体マイク」は HFP に切り替えない(= BT が落ちない・TsukaimaMic と同じ経路)。従来の挙動は「イヤホン/ヘッドセット」で残す。
enum ConverseMicMode: String, CaseIterable, Identifiable {
    case builtIn
    case headset
    case auto

    var id: String { rawValue }
    static let defaultsKey = "tsukaima.converse.micMode"

    var label: String {
        switch self {
        case .builtIn: "本体マイク"
        case .headset: "イヤホン/ヘッドセットのマイク"
        case .auto: "自動"
        }
    }

    static var current: ConverseMicMode {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(ConverseMicMode.init(rawValue:)) ?? .builtIn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 実際に使うマイク。
    enum Choice: Equatable { case builtIn, headset }

    /// auto: すでに BT が HFP(通話用)で繋がっているときだけヘッドセット。A2DP のイヤホンや有線・本体は本体側のマイク
    /// (有線ヘッドセットのマイクは、本体マイクを選んでいても OS が自動で使う)。
    func resolve(hfpOutputActive: Bool) -> Choice {
        switch self {
        case .builtIn: .builtIn
        case .headset: .headset
        case .auto: hfpOutputActive ? .headset : .builtIn
        }
    }
}

enum ConverseAudioPolicy {
    /// Voice Processing(エコー消去)を使うか。BT イヤホンの出力+本体マイクのときは、音がマイクに回り込まないので使わない
    /// (VP は BT と組むと入力が無音になったり HFP に引っぱられたりする。録音専用の TsukaimaMic と同じ素の経路にする)。
    static func useVoiceProcessing(choice: ConverseMicMode.Choice, bluetoothOutput: Bool) -> Bool {
        switch choice {
        case .headset: true
        case .builtIn: !bluetoothOutput
        }
    }

    /// 経路変更・構成変更の通知を 1 回の再起動にまとめるときの静まり待ち(秒)
    static let routeSettle = 0.5
    /// この秒数のうちに restartCap 回を超えて再起動したら、ループとみなして止める
    static let restartWindow = 60.0
    static let restartCap = 8
}

/// 再起動の回数の上限(ループ止め)。時計は呼び出し側が渡す。
struct ConverseRestartCap {
    private var times: [Double] = []

    /// 再起動してよければ true(回数に数える)。上限を超えたら false。
    mutating func allow(now: Double) -> Bool {
        times.removeAll { now - $0 > ConverseAudioPolicy.restartWindow }
        guard times.count < ConverseAudioPolicy.restartCap else { return false }
        times.append(now)
        return true
    }

    mutating func reset() { times.removeAll() }
}

/// tap の統計(tap スレッドで足し、診断タイマーで読む。呼び出し側が鍵で守る)。launch のたびに作り直す。
struct ConverseTapStats {
    var callbacks = 0
    var frames = 0
    var sumSquares = 0.0
    var peak: Float = 0
    var everNonZero = false
    var lastCallbackAt = 0.0
    let launchedAt: Double

    init(launchedAt: Double) { self.launchedAt = launchedAt }

    mutating func add(frames n: Int, sumSquares s: Double, peak p: Float, now: Double) {
        callbacks += 1
        frames += n
        sumSquares += s
        peak = max(peak, p)
        if p > 0 { everNonZero = true }
        lastCallbackAt = now
    }

    /// 診断ログ用に区間の値を取り出して、区間の積算(frames/rms/peak)をリセットする
    mutating func drain() -> (frames: Int, rms: Double, peak: Float) {
        let r = frames > 0 ? (sumSquares / Double(frames)).squareRoot() : 0
        let out = (frames, r, peak)
        frames = 0
        sumSquares = 0
        peak = 0
        return out
    }
}

enum ConverseTapVerdict: Equatable {
    case waiting      // 起動直後
    case healthy
    case noCallbacks  // 起動から一度も tap が呼ばれない
    case stalled      // 流れていた tap が止まった
    case allZero      // 起動から一度も 0 でない音が来ない(VP+BT で起きる「無音の入力」)
}

enum ConverseTapJudge {
    static let noCallbackAfter = 3.0
    static let stallAfter = 3.0
    static let allZeroAfter = 8.0

    static func judge(_ s: ConverseTapStats, now: Double) -> ConverseTapVerdict {
        let since = now - s.launchedAt
        if s.callbacks == 0 { return since >= noCallbackAfter ? .noCallbacks : .waiting }
        if now - s.lastCallbackAt >= stallAfter { return .stalled }
        // 音が来ているのは 1 度でも確認できれば信用する(VP は再生中などに正当に 0 を返すことがあるので、その後は問わない)
        if !s.everNonZero && since >= allZeroAfter { return .allZero }
        return s.everNonZero ? .healthy : .waiting
    }
}

/// 無音・停止が続いたときの立て直しの段階。段階ごとに 1 つずつ強い手に進み、最後はあきらめて本人に伝える。
enum ConverseRecovery: Equatable {
    case rebuildEngine         // エンジンを作り直して tap を付け直す
    case rebuildWithoutVP      // Voice Processing をやめる
    case fallbackToBuiltIn     // ヘッドセットのマイクをやめ、本体マイク+VP なしにする
    case giveUp

    static func step(attempt: Int, choice: ConverseMicMode.Choice) -> ConverseRecovery {
        switch attempt {
        case ...1: return .rebuildEngine
        case 2: return .rebuildWithoutVP
        case 3: return choice == .headset ? .fallbackToBuiltIn : .giveUp
        default: return .giveUp
        }
    }
}
