import Foundation

// 会話モードの「黙って壊れない」ための純粋な規則(時計は呼び出し側が渡す。単体テストできる)。
// 場面番号(S10 など)は portal-bot/docs/convmode-robustness-2026-10-28.md の総当たり表。

/// サーバーから届く JSON(docs/converse-protocol.md 1章)。ConverseLink.handleText の中身を純粋にしたもの。
enum ConverseServerMessage: Equatable {
    case state(String)
    case transcript(text: String, final: Bool)
    case audio(ConverseLink.AudioHeader)
    case replyText(String)
    /// 約 10 秒ごと。state はサーバーの現在の状態(アプリの表示と違えばサーバーに合わせる)
    case ping(state: String?)
    /// 声の合成が全滅(sent=0)か途中で止まった(sent=送れた本数)。text は返事の全文
    case speechFailed(text: String, sent: Int)
    /// 端末で読み上げる知らせ(stt_slow など)
    case notice(code: String, say: String)
    /// reply_delivery=hold で返事を溜めた
    case held(count: Int)
    case unknown(String)

    static func parse(_ s: String) -> ConverseServerMessage? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
              let type = o["type"] as? String else { return nil }
        switch type {
        case "state":
            guard let st = o["state"] as? String else { return nil }
            return .state(st)
        case "transcript":
            return .transcript(text: o["text"] as? String ?? "", final: (o["final"] as? Bool) ?? false)
        case "audio":
            guard let id = o["id"] as? String else { return nil }
            return .audio(ConverseLink.AudioHeader(id: id, kind: o["kind"] as? String ?? "speech",
                                                   format: o["format"] as? String ?? "wav",
                                                   bytes: (o["bytes"] as? NSNumber)?.intValue ?? 0))
        case "reply_text":
            return .replyText(o["text"] as? String ?? "")
        case "ping":
            return .ping(state: o["state"] as? String)
        case "speech_failed":
            return .speechFailed(text: o["text"] as? String ?? "", sent: (o["sent"] as? NSNumber)?.intValue ?? 0)
        case "notice":
            return .notice(code: o["code"] as? String ?? "", say: o["say"] as? String ?? "")
        case "held":
            return .held(count: (o["count"] as? NSNumber)?.intValue ?? 0)
        default:
            return .unknown(type)
        }
    }
}

/// A1(S10・S13): 受信ウォッチドッグ。ping も音声も state も `limit` 秒届かなければ半開きの回線とみなす。
struct ConverseRxWatchdog: Equatable {
    static let limit = 25.0
    private(set) var lastReceived: Double?

    /// 接続が開いた・何か届いた
    mutating func touch(now: Double) { lastReceived = now }
    mutating func reset() { lastReceived = nil }

    /// 張り直すべきか(開いていて、最後の受信から limit 秒を超えた)
    func isStale(now: Double) -> Bool {
        guard let t = lastReceived else { return false }
        return now - t > Self.limit
    }
}

/// A3(S11・S12): つながらない状態が続くときの端末側の知らせ。
/// 接続待ちが `firstWait` 秒続いたら 1 回目、以後 `repeatEvery` 秒おき。つながれば消える。
struct ConverseOutageNotifier: Equatable {
    static let firstWait = 20.0
    static let repeatEvery = 120.0
    static let phrase = "使い魔につながりません。つながるまで待っています。"

    private(set) var since: Double?
    private(set) var nextDue: Double?

    /// 接続待ちに入った(すでに待っていれば何もしない)
    mutating func began(now: Double) {
        guard since == nil else { return }
        since = now
        nextDue = now + Self.firstWait
    }

    /// つながった・止めた
    mutating func ended() {
        since = nil
        nextDue = nil
    }

    /// 時計を進めたとき、知らせるべきなら true(次の期限を進める)
    mutating func tick(now: Double) -> Bool {
        guard let due = nextDue, now >= due else { return false }
        nextDue = now + Self.repeatEvery
        return true
    }
}

/// A2(S03・S04・S07): 声にできなかった時に端末で言う文。
enum ConverseLocalPhrase {
    static let continuationLost = "続きは声にできませんでした。画面に出しています。"
    static let authExpired = "使い魔の認証が切れました。アプリを開いて登録し直してください。"
    static let audioStopped = "会話モードの音声が止まりました。復帰を試みます。"
    static let audioGaveUp = "会話モードの音声を復帰できませんでした。会話モードを止めます。"
    static let routeLost = "イヤホンが外れたので、返事はためておきます。読んで、と言えば再生します。"

    /// speech_failed の読み方: 全滅なら本文を全部、途中からなら重ねて全部は読まず一言だけ
    static func forSpeechFailed(text: String, sent: Int) -> String? {
        if sent > 0 { return continuationLost }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// A4(S17): 再生ウォッチドッグの期限。wav の長さ+余裕で、完了が来なくても次へ進む。
enum ConversePlaybackWatchdog {
    static let grace = 5.0

    /// frames / sampleRate + grace。壊れた値(0 以下)でも最低 grace 秒は待つ。
    static func deadline(frames: Int64, sampleRate: Double) -> Double {
        guard frames > 0, sampleRate > 0 else { return grace }
        return Double(frames) / sampleRate + grace
    }
}

/// A4(S16・S18): 音声の自動復帰を何回まで・どの間隔で試すか。
struct ConverseRecoveryPolicy: Equatable {
    static let interval = 30.0
    static let maxAttempts = 10

    private(set) var attempts = 0

    /// 次を試してよければその待ち秒数、もう諦めるなら nil
    mutating func nextDelay() -> Double? {
        guard attempts < Self.maxAttempts else { return nil }
        attempts += 1
        return Self.interval
    }

    /// 復帰できた
    mutating func recovered() { attempts = 0 }
}

/// A5(S20): 音の経路が変わった理由ごとの扱い。
/// AVAudioSession.RouteChangeReason の rawValue: 1=newDeviceAvailable 2=oldDeviceUnavailable
enum ConverseRouteChange: Equatable {
    /// イヤホンなどが外れた。スピーカーに切り替わる前に再生を止め、返事を溜める
    case deviceLost
    /// イヤホンなどが付いた。自分で溜めたのなら元に戻す
    case deviceGained
    case other

    static func classify(reasonRaw: UInt) -> ConverseRouteChange {
        switch reasonRaw {
        case 1: return .deviceGained
        case 2: return .deviceLost
        default: return .other
        }
    }
}

/// A5: 返事の溜め(reply_delivery=hold)を「経路が外れたから自分で掛けた」ときだけ外す規則。
struct ConverseHoldByRoute: Equatable {
    private(set) var holdingByRoute = false

    /// 外れた: hold を掛けるべきなら true(すでに掛けていれば false)
    mutating func lost() -> Bool {
        guard !holdingByRoute else { return false }
        holdingByRoute = true
        return true
    }

    /// 付いた: 自分で掛けた hold を外すべきなら true
    mutating func gained() -> Bool {
        guard holdingByRoute else { return false }
        holdingByRoute = false
        return true
    }

    mutating func reset() { holdingByRoute = false }
}
