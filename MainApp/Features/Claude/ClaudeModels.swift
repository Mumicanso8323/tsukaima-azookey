import Foundation

/// `/ws/claude` の 1 イベント(docs/converse-protocol.md 2章)。
/// data の中身はイベントの種類によって形が違う(本文の断片、thinking の断片、ツール名+入力、結果など)ので、
/// ここでは JSON のまま保持し、表示側(ClaudeTimelineView)が kind ごとに読む。
struct ClaudeEvent: Identifiable, Equatable {
    enum Kind: String {
        case user, text, thinking, toolUse = "tool_use", toolResult = "tool_result", system, result, error
    }

    let id = UUID()
    let seq: Int
    let kind: Kind
    let raw: [String: Any]
    let at: Date?
    /// どのセッションのイベントか(複数セッション対応。docs/converse-protocol.md 2章)。
    let session: String?

    static func == (lhs: ClaudeEvent, rhs: ClaudeEvent) -> Bool { lhs.id == rhs.id }

    static func parse(_ obj: [String: Any]) -> ClaudeEvent? {
        guard let seq = (obj["seq"] as? NSNumber)?.intValue,
              let kindRaw = obj["kind"] as? String,
              let kind = Kind(rawValue: kindRaw) else { return nil }
        let data = obj["data"] as? [String: Any] ?? [:]
        let at = (obj["at"] as? String).flatMap(ClaudeEvent.parseDate)
        return ClaudeEvent(seq: seq, kind: kind, raw: data, at: at, session: obj["session"] as? String)
    }

    /// text/thinking/error でよく使う本文の文字列(サーバーの断片名がどれになっても拾えるように複数試す)
    var text: String {
        for key in ["text", "delta", "message", "content"] {
            if let s = raw[key] as? String { return s }
        }
        return ""
    }

    var toolName: String? { raw["name"] as? String ?? raw["tool"] as? String }
    var toolInputSummary: String? {
        if let s = raw["input"] as? String { return s }
        if let d = raw["input"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: d),
           let s = String(data: data, encoding: .utf8) { return s }
        return nil
    }
    var toolOutputSummary: String? {
        for key in ["output", "result", "content", "text"] {
            if let s = raw[key] as? String { return s }
        }
        return nil
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions.insert(.withFractionalSeconds)
        return iso.date(from: s)
    }

    // ---- 表示の分類(実機の不具合対応: 内部用の文をそのまま出さない) ----

    var source: String? { raw["source"] as? String }
    var isMeta: Bool { (raw["meta"] as? Bool) == true || source == "meta" }
    var isChannelVoice: Bool { kind == .user && source == "channel" }
    var systemSubtype: String? { raw["subtype"] as? String }

    /// `<command-name>...</command-name>` や `<local-command-stdout>...</local-command-stdout>` の生タグ
    /// (サーバー側を直してもバージョン差で紛れ込むことがあるので、アプリ側でも念のため見る)。
    var looksLikeRawCommandTag: Bool {
        let t = text
        return t.hasPrefix("<command-") || t.hasPrefix("<local-command-")
    }

    /// ローカルコマンドの応答(「Set effort level to medium」など)。1行の控えめな表示にする(隠さない)。
    var isLocalCommandResult: Bool { kind == .system && systemSubtype == "local_command" }

    /// system のうち、hook・フックの知らせなど「日常は見なくてよい」もの。トグルでだけ出す。
    var isInformationalSystem: Bool {
        kind == .system && !isLocalCommandResult && systemSubtype != "bridge_status" && systemSubtype != "compact_boundary"
    }

    /// 既定で隠す(「詳細を表示」トグルでだけ出す)条件。
    var isHiddenByDefault: Bool {
        switch kind {
        case .user: return isMeta || looksLikeRawCommandTag
        case .system: return isInformationalSystem
        default: return false
        }
    }

    var toolUseID: String? { raw["id"] as? String }
    var toolResultForID: String? { raw["tool_use_id"] as? String }
    var isToolError: Bool { (raw["is_error"] as? Bool) == true }
    /// コピー用の本文(返事ツールなら読み上げ原稿)
    var copyText: String { replyText ?? text }
    var isReplyToolUse: Bool { kind == .toolUse && toolName == "mcp__tsukaima__reply" }

    /// mcp__tsukaima__reply の input.text(読み上げ原稿=本体の返事そのもの)。
    var replyText: String? {
        guard let d = raw["input"] as? [String: Any], let t = d["text"] as? String, !t.isEmpty else { return nil }
        return t
    }
}

/// {"type":"status",...}
struct ClaudeStatus: Equatable {
    var busy = false
    var model: String?
    var effort: String?
    var cwd: String?
    var project: String?
    /// いま見ているセッション(複数セッション対応)。省略時(常駐)は session_id と同じ値になる。
    var sessionID: String?
    /// `claude agents` の名前(常駐は "converse")。
    var name: String?
    /// そのセッションに使い魔チャンネルがつながっていれば true(send/keys ができる)。false は閲覧のみ。
    var channel = true
    var remoteURL: String?

    static func parse(_ obj: [String: Any]) -> ClaudeStatus {
        ClaudeStatus(busy: (obj["busy"] as? Bool) ?? false,
                    model: obj["model"] as? String,
                    effort: obj["effort"] as? String,
                    cwd: obj["cwd"] as? String,
                    project: obj["project"] as? String,
                    sessionID: (obj["session"] as? String) ?? (obj["session_id"] as? String),
                    name: obj["name"] as? String,
                    channel: (obj["channel"] as? Bool) ?? true,
                    remoteURL: obj["remote_url"] as? String)
    }
}

/// GET /api/claude/projects の 1 件
struct ClaudeProject: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let cwd: String
}

/// GET /api/claude/sessions の 1 件(docs/converse-protocol.md 2章、複数セッション対応)。
struct ClaudeSessionInfo: Identifiable, Equatable {
    var id: String { sessionID }
    let sessionID: String
    let name: String
    let cwd: String?
    /// "busy" | "idle" | "unknown"
    let status: String
    /// チャンネルがつながっていれば送信できる(send/keys)。false は記録の閲覧のみ。
    let channel: Bool
    var isConverse: Bool { name == "converse" }

    static func parse(_ obj: [String: Any]) -> ClaudeSessionInfo? {
        guard let sid = obj["session_id"] as? String else { return nil }
        return ClaudeSessionInfo(sessionID: sid, name: (obj["name"] as? String) ?? sid,
                                 cwd: obj["cwd"] as? String, status: (obj["status"] as? String) ?? "unknown",
                                 channel: (obj["channel"] as? Bool) ?? false)
    }
}
