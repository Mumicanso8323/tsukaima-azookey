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

    static func == (lhs: ClaudeEvent, rhs: ClaudeEvent) -> Bool { lhs.id == rhs.id }

    static func parse(_ obj: [String: Any]) -> ClaudeEvent? {
        guard let seq = (obj["seq"] as? NSNumber)?.intValue,
              let kindRaw = obj["kind"] as? String,
              let kind = Kind(rawValue: kindRaw) else { return nil }
        let data = obj["data"] as? [String: Any] ?? [:]
        let at = (obj["at"] as? String).flatMap(ClaudeEvent.parseDate)
        return ClaudeEvent(seq: seq, kind: kind, raw: data, at: at)
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
}

/// {"type":"status",...}
struct ClaudeStatus: Equatable {
    var busy = false
    var model: String?
    var effort: String?
    var cwd: String?
    var project: String?

    static func parse(_ obj: [String: Any]) -> ClaudeStatus {
        ClaudeStatus(busy: (obj["busy"] as? Bool) ?? false,
                    model: obj["model"] as? String,
                    effort: obj["effort"] as? String,
                    cwd: obj["cwd"] as? String,
                    project: obj["project"] as? String)
    }
}

/// GET /api/claude/projects の 1 件
struct ClaudeProject: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let cwd: String
}
