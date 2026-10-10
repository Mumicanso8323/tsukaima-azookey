import Foundation

/// /ws/blind の `reply`(proto 2)。
struct BlindReply: Equatable, Sendable, Codable {
    enum Audio: String, Equatable, Sendable, Codable {
        case send
        /// 音は別の接続が鳴らす(または TEXT)。rawValue はサーバーの "none"。
        case muted = "none"
    }

    let rid: Int
    let epoch: String
    let text: String
    let question: Bool
    /// サーバーが返事を受け取った時刻(epoch 秒)
    let at: Double
    let origin: String
    let replay: Bool
    let audio: Audio
    let why: String?

    /// rid / epoch / text が欠けたり型違いなら nil。ほかは既定値で補う。
    static func parse(_ object: [String: Any]) -> BlindReply? {
        guard let rid = BlindJSON.int(object["rid"]),
              let epoch = object["epoch"] as? String,
              let text = object["text"] as? String else { return nil }
        let at = BlindJSON.double(object["at"]) ?? 0
        return BlindReply(
            rid: rid,
            epoch: epoch,
            text: text,
            question: object["question"] as? Bool ?? false,
            at: at,
            origin: object["origin"] as? String ?? "other",
            replay: object["replay"] as? Bool ?? false,
            audio: Audio(rawValue: object["audio"] as? String ?? "") ?? Audio.muted,
            why: object["why"] as? String
        )
    }
}

/// JSONSerialization の数値読み(Bool を数として読まない)。
enum BlindJSON {
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number.intValue
    }

    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number.doubleValue
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// 返事カードの長さの規則(DEC-9)。Swift の Character(拡張書記素クラスタ)で数える。
enum BlindReplyLayout {
    static let previewLimit = 240

    struct Preview: Equatable {
        /// 先頭 previewLimit 字まで
        let shown: String
        let total: Int
        let isTruncated: Bool

        /// カードに出す文。超えたときだけ「…(全 N 字)」を付ける。
        var displayText: String {
            isTruncated ? "\(shown)…(全 \(total) 字)" : shown
        }
    }

    static func preview(_ text: String) -> Preview {
        let total = text.count
        guard total > previewLimit else {
            return Preview(shown: text, total: total, isTruncated: false)
        }
        return Preview(shown: String(text.prefix(previewLimit)), total: total, isTruncated: true)
    }
}

/// 同じ返事を 1 回だけ処理するための規則(epoch/rid)。
struct BlindReplyDeduper {
    private(set) var lastEpoch: String?
    private(set) var lastRid = 0

    init() {}

    init(epoch: String, rid: Int) {
        lastEpoch = epoch
        lastRid = rid
    }

    /// 同じ epoch は rid が増えたときだけ。epoch が違う(サーバー再起動)ときは受けて、基準を取り直す。
    mutating func accept(epoch: String, rid: Int) -> Bool {
        if let lastEpoch, lastEpoch == epoch, rid <= lastRid {
            return false
        }
        lastEpoch = epoch
        lastRid = rid
        return true
    }
}

/// 最後の 1 件と rid/epoch の保存(画面の寿命と独立。DEC-10)。UserDefaults に JSON で持つので、アプリ再起動後もカードに出せる。
@MainActor
final class BlindReplyStore: ObservableObject {
    static let key = "blind.reply.last.v1"

    @Published private(set) var last: BlindReply?
    @Published private(set) var unread = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let reply = try? JSONDecoder().decode(BlindReply.self, from: data) {
            last = reply
        }
    }

    /// 重複排除の起点(保存済みの最後の返事)。
    func makeDeduper() -> BlindReplyDeduper {
        guard let last else { return BlindReplyDeduper() }
        return BlindReplyDeduper(epoch: last.epoch, rid: last.rid)
    }

    /// 新しい返事を最新 1 件として置く。見ていない返事の数を数える。
    func register(_ reply: BlindReply) {
        last = reply
        unread += 1
        if let data = try? JSONEncoder().encode(reply) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func markSeen() {
        if unread != 0 { unread = 0 }
    }

    /// 「未読 +n」の n: 最新 1 件のほかに、見ないまま置き換わった数。
    var replacedUnread: Int { max(unread - 1, 0) }
}
