import Foundation

// /api/main/view・/api/main/send・/api/survey・/api/inbox の応答(bot/web.py・mainsession.py・survey.py・inbox.py)。
// デコードは CSNet(snake_case → camelCase)。

/// GET /api/main/view → {file, turns, status, queue}
struct ChatView: Decodable, Sendable {
    var turns: [ChatTurn]
    var status: ChatStatus?
    var queue: [ChatQueueItem]

    enum CodingKeys: String, CodingKey { case turns, status, queue }
    init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        turns = (try? c.decode([ChatTurn].self, forKey: .turns)) ?? []
        status = try? c.decode(ChatStatus.self, forKey: .status)
        queue = (try? c.decode([ChatQueueItem].self, forKey: .queue)) ?? []
    }
}

/// 記録の 1 行。r = "me" | "ai" | "tool"。tool は n 回・names(使った道具)
struct ChatTurn: Decodable, Sendable, Equatable {
    var r: String
    var t: String?
    var ts: String?
    var n: Int?
    var names: [String?]?
}

/// メインのセッションとの接続状態
struct ChatStatus: Decodable, Sendable, Equatable {
    var connected: Bool?
    var session: String?
    var pending: Int?
    var reason: String?
}

/// 送信キュー(hub が保留・届け済みを管理)
struct ChatQueueItem: Decodable, Sendable, Equatable, Identifiable {
    var id: String
    var ts: String?
    var text: String?
    var status: String?
    var reason: String?
    var deliveredAt: String?
}

/// GET /api/survey → {open, answered}
struct SurveyList: Decodable, Sendable {
    var open: [SurveyItem]
    var answered: [SurveyItem]
}

struct SurveyItem: Decodable, Sendable, Identifiable, Equatable {
    var id: String
    var topic: String?
    var question: String?
    var why: String?
    var choices: [String]?
    var multi: Bool?
    var allowText: Bool?
    var answered: String?
    var answer: SurveyAnswer?
}

struct SurveyAnswer: Decodable, Sendable, Equatable {
    var choices: [String]?
    var text: String?
}

/// GET/POST /api/inbox の 1 件(「Claude に伝える」の伝言)
struct InboxMessage: Decodable, Sendable, Equatable {
    var ts: String?
    var text: String?
    var ref: String?
    var status: String?
}

/// 使い魔タブの入力欄に外から文を入れる(「使い魔に聞く」)。本文は渡さず、どの画面の物かの参照だけを入れる。
/// 他の画面からは `ChatPrefill.shared.ask(ref:)` を呼んでから使い魔タブへ切り替える。
@MainActor
final class ChatPrefill: ObservableObject {
    static let shared = ChatPrefill()
    @Published var text: String?

    func ask(ref: String) { text = "(使い魔の画面: \(ref)) " }
}
