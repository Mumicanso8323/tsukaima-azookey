import Foundation

// イベントの列(ClaudeEvent)を、画面に並べる「項目」(ClaudeItem)にまとめる。Foundation だけに依存する純ロジック。
// 公式の Claude アプリと同じ見せ方にするための決まり:
//   - 本人の発言は右の吹き出し。添付(サーバーが本文の末尾に付ける `@/絶対パス`)は本文から外して、縮小表示/チップにする。
//   - Claude の返事(text と mcp__tsukaima__reply)は Markdown の本文。続けて来た text は 1 つにまとめる。
//   - ツール呼び出しと thinking は、本文と本文の間で 1 つの「作業のまとまり」(1 行)に畳む。タップで中の一覧を開き、
//     各呼び出しはさらにタップで入力・出力を見る。生の出力は既定では出さない。
//   - Write/Edit で作った・直した閲覧できるファイル(html・md・画像・pdf など)は、まとまりの後に「成果物」のカードで出す。
//   - hook の知らせ・Claude Code が自動で差し込んだ文・ターン終了などの内部の行は既定で出さない(詳細トグルで出す)。

/// 1 回のツール呼び出し(tool_use と、あとから来る tool_result を合わせたもの)
struct ClaudeToolCall: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// 種類の短い名前(「コマンド」「読む」「編集」…)
    let verb: String
    /// SF Symbols の名前
    let icon: String
    /// 1 行の要約(コマンドの説明・ファイル名・検索語など)
    let title: String
    /// 開いたときに見せる入力(整形済み)
    let input: String
    /// Edit の差分(old → new)
    var edit: ClaudeEditDiff?
    /// 対象ファイルの絶対パス(Read/Write/Edit)
    var filePath: String?
    var output: String?
    var isError = false
    var truncated = false
    var hasResult: Bool { output != nil || isError }
}

struct ClaudeEditDiff: Equatable, Sendable {
    let old: String
    let new: String
}

/// 本文と本文の間の、ツール呼び出しと thinking のまとまり
struct ClaudeActivity: Identifiable, Equatable, Sendable {
    enum Step: Equatable, Sendable, Identifiable {
        case tool(ClaudeToolCall)
        case thinking(id: String, text: String)
        var id: String {
            switch self {
            case .tool(let c): return c.id
            case .thinking(let id, _): return id
            }
        }
    }

    let id: String
    var steps: [Step]

    var calls: [ClaudeToolCall] {
        steps.compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
    }

    /// まだ結果が来ていない呼び出しがあるか(作業中の表示に使う)
    var hasPending: Bool { calls.contains { !$0.hasResult } }
    var errorCount: Int { calls.filter(\.isError).count }

    /// 1 行の見出し。1 件なら「<種類> <要約>」、複数なら種類ごとの件数「コマンド 3・読む 2」。
    var summary: String {
        let cs = calls
        if cs.isEmpty { return "考えています" }
        if cs.count == 1, let c = cs.first { return c.title.isEmpty ? c.verb : "\(c.verb) \(c.title)" }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for c in cs {
            if counts[c.verb] == nil { order.append(c.verb) }
            counts[c.verb, default: 0] += 1
        }
        return order.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: "・")
    }

    /// 見出しの横に出す、いちばん最近の呼び出しの要約(作業中の表示用)
    var latestTitle: String? {
        guard let c = calls.last else { return nil }
        return c.title.isEmpty ? c.verb : "\(c.verb) \(c.title)"
    }

    var icon: String { calls.count == 1 ? (calls.first?.icon ?? "sparkles") : "square.stack.3d.up" }
}

struct ClaudeAttachmentRef: Equatable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    var name: String { (path as NSString).lastPathComponent.replacingOccurrences(of: #"^[0-9a-f]{16}_"#, with: "", options: .regularExpression) }
    var isImage: Bool { ClaudeFileKind(path: path) == .image }
}

/// ファイルの見せ方の種類(拡張子から)
enum ClaudeFileKind: Equatable, Sendable {
    case image, pdf, html, markdown, csv, code, text, office, other

    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "svg": self = .image
        case "pdf": self = .pdf
        case "html", "htm": self = .html
        case "md", "markdown": self = .markdown
        case "csv", "tsv": self = .csv
        case "swift", "py", "js", "jsx", "ts", "tsx", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "rb", "php",
             "sh", "bash", "zsh", "json", "yaml", "yml", "toml", "xml", "css", "scss", "sql", "lua", "pbxproj", "plist", "ini", "conf":
            self = .code
        case "txt", "log", "jsonl", "ndjson", "env.example": self = .text
        case "docx", "doc", "xlsx", "xls", "pptx", "ppt", "key", "pages", "numbers", "rtf": self = .office
        default: self = ext.isEmpty ? .text : .other
        }
    }

    /// 成果物のカードを出す種類(Claude が作ったものとして見たいもの)
    var isArtifact: Bool {
        switch self {
        case .image, .pdf, .html, .markdown, .csv, .office: return true
        default: return false
        }
    }

    var icon: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .html: return "globe"
        case .markdown: return "doc.text"
        case .csv: return "tablecells"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext"
        case .office: return "doc"
        case .other: return "doc"
        }
    }
}

enum ClaudeItem: Identifiable, Equatable, Sendable {
    /// 本人の発言。voice は声(会話モード)から来たもの。
    case user(id: String, text: String, attachments: [ClaudeAttachmentRef], voice: Bool)
    /// Claude の返事(Markdown の原文)
    case assistant(id: String, markdown: String)
    case activity(ClaudeActivity)
    /// Claude が作った/直した、アプリで見られるファイル
    case artifact(id: String, path: String, kind: ClaudeFileKind, edited: Bool)
    /// 控えめな 1 行(ローカルコマンドの応答・要約の区切り・詳細表示時の内部の行)
    case note(id: String, text: String, icon: String)
    case error(id: String, text: String)

    var id: String {
        switch self {
        case .user(let id, _, _, _), .assistant(let id, _), .artifact(let id, _, _, _), .note(let id, _, _), .error(let id, _):
            return id
        case .activity(let a):
            return a.id
        }
    }
}

enum ClaudeTranscript {
    /// イベント列 → 項目。showDetails のときは既定で隠す行も出す。
    static func build(_ events: [ClaudeEvent], showDetails: Bool) -> [ClaudeItem] {
        var items: [ClaudeItem] = []
        var activity: ClaudeActivity?
        var activityIndex: Int?            // items の中での位置(結果が後から来たら書き換える)
        var callLocation: [String: (item: Int, step: Int)] = [:]
        var writtenInActivity: [(path: String, edited: Bool)] = []
        // 直前の項目が「続けてよい返事」か(ターンの終わり・本人の発言などを挟んだら別の返事にする)
        var assistantOpen = false
        let replyIDs = Set(events.filter(\.isReplyToolUse).compactMap(\.toolUseID))

        func closeActivity() {
            guard activity != nil else { return }
            activity = nil
            activityIndex = nil
            // まとまりの後に成果物のカード(同じパスは最後の 1 回だけ)
            var seen = Set<String>()
            for w in writtenInActivity.reversed() where !seen.contains(w.path) {
                seen.insert(w.path)
                items.append(.artifact(id: "art-\(items.count)-\(w.path)", path: w.path, kind: ClaudeFileKind(path: w.path), edited: w.edited))
            }
            writtenInActivity.removeAll()
        }

        func appendStep(_ step: ClaudeActivity.Step, seq: Int) {
            if activity == nil {
                activity = ClaudeActivity(id: "act-\(seq)", steps: [])
                items.append(.activity(activity!))
                activityIndex = items.count - 1
            }
            activity!.steps.append(step)
            if case .tool(let c) = step, let idx = activityIndex {
                callLocation[c.id] = (idx, activity!.steps.count - 1)
            }
            if let idx = activityIndex { items[idx] = .activity(activity!) }
        }

        func appendAssistant(_ text: String, seq: Int) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            closeActivity()
            // 続けて来た本文は 1 つにまとめる
            if assistantOpen, case .assistant(let id, let prev)? = items.last {
                items[items.count - 1] = .assistant(id: id, markdown: prev + "\n\n" + trimmed)
            } else {
                items.append(.assistant(id: "a-\(seq)", markdown: trimmed))
            }
            assistantOpen = true
        }

        for ev in events {
            let isAssistantText = ev.kind == .text || (ev.kind == .toolUse && ev.isReplyToolUse)
            if !isAssistantText, ev.kind != .toolResult { assistantOpen = false }
            switch ev.kind {
            case .user:
                if ev.isHiddenByDefault {
                    if showDetails { items.append(.note(id: "n-\(ev.seq)", text: ev.text, icon: "info.circle")) }
                    continue
                }
                closeActivity()
                let (text, refs) = splitAttachments(ev.text)
                items.append(.user(id: "u-\(ev.seq)", text: text, attachments: refs, voice: ev.isChannelVoice))

            case .text:
                appendAssistant(ev.text, seq: ev.seq)

            case .thinking:
                let t = ev.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 伏せ字(redacted)や空の thinking は出さない(何も読めない行はうるさいだけ)
                guard !t.isEmpty else { continue }
                appendStep(.thinking(id: "t-\(ev.seq)", text: t), seq: ev.seq)

            case .toolUse:
                if ev.isReplyToolUse {
                    if let reply = ev.replyText { appendAssistant(reply, seq: ev.seq) }
                    continue
                }
                let call = toolCall(ev)
                appendStep(.tool(call), seq: ev.seq)
                if let p = call.filePath, call.name == "Write" || call.name == "Edit" || call.name == "MultiEdit",
                   ClaudeFileKind(path: p).isArtifact {
                    writtenInActivity.append((p, call.name != "Write"))
                }

            case .toolResult:
                guard let rid = ev.toolResultForID else { continue }
                if replyIDs.contains(rid) { continue }
                guard let loc = callLocation[rid], case .activity(var act) = items[loc.item],
                      loc.step < act.steps.count, case .tool(var call) = act.steps[loc.step] else { continue }
                call.output = ev.toolOutputSummary ?? ""
                call.isError = (ev.raw["is_error"] as? Bool) ?? false
                call.truncated = (ev.raw["truncated"] as? Bool) ?? false
                act.steps[loc.step] = .tool(call)
                items[loc.item] = .activity(act)
                if activityIndex == loc.item { activity = act }

            case .system:
                if ev.isLocalCommandResult {
                    items.append(.note(id: "n-\(ev.seq)", text: ev.text, icon: "terminal"))
                } else if ev.systemSubtype == "compact_boundary" {
                    closeActivity()
                    items.append(.note(id: "n-\(ev.seq)", text: "ここまでの会話を要約しました", icon: "arrow.down.right.and.arrow.up.left"))
                } else if showDetails, !ev.text.isEmpty {
                    items.append(.note(id: "n-\(ev.seq)", text: ev.text, icon: "info.circle"))
                }

            case .result:
                closeActivity()
                if showDetails {
                    let ms = (ev.raw["duration_ms"] as? NSNumber)?.intValue
                    items.append(.note(id: "n-\(ev.seq)", text: ms.map { "完了(\(Self.duration(ms: $0)))" } ?? "完了", icon: "flag.checkered"))
                }

            case .error:
                closeActivity()
                items.append(.error(id: "e-\(ev.seq)", text: ev.text.isEmpty ? "エラーが発生しました" : ev.text))
            }
        }
        closeActivity()
        return items
    }

    // MARK: 添付

    private static let attachmentRegex = try? NSRegularExpression(pattern: #"(?:^|\s)@(/[^\s]+)"#)

    /// サーバーが本文の末尾に付ける `@/絶対パス` を取り出して、本文から外す
    static func splitAttachments(_ text: String) -> (String, [ClaudeAttachmentRef]) {
        guard let re = attachmentRegex else { return (text, []) }
        let ns = text as NSString
        var refs: [ClaudeAttachmentRef] = []
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let path = ns.substring(with: m.range(at: 1))
            refs.insert(ClaudeAttachmentRef(path: path), at: 0)
            out = (out as NSString).replacingCharacters(in: m.range, with: "")
        }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), refs)
    }

    // MARK: ツールの要約

    static func toolCall(_ ev: ClaudeEvent) -> ClaudeToolCall {
        let name = ev.toolName ?? "ツール"
        let input = ev.raw["input"] as? [String: Any] ?? [:]
        func str(_ k: String) -> String? {
            guard let s = input[k] as? String, !s.isEmpty else { return nil }
            return s
        }
        func base(_ p: String?) -> String { p.map { ($0 as NSString).lastPathComponent } ?? "" }
        let id = ev.toolUseID ?? "tool-\(ev.seq)"
        var verb = name
        var icon = "wrench.and.screwdriver"
        var title = ""
        var filePath: String?
        var edit: ClaudeEditDiff?

        switch name {
        case "Bash", "BashOutput":
            verb = "コマンド"; icon = "terminal"
            title = str("description") ?? firstLine(str("command") ?? "")
        case "KillShell", "KillBash":
            verb = "停止"; icon = "stop.circle"; title = str("shell_id") ?? ""
        case "Read":
            verb = "読む"; icon = "doc.text"; filePath = str("file_path"); title = base(filePath)
        case "Write":
            verb = "作成"; icon = "doc.badge.plus"; filePath = str("file_path"); title = base(filePath)
        case "Edit", "MultiEdit":
            verb = "編集"; icon = "pencil"; filePath = str("file_path"); title = base(filePath)
            if let o = input["old_string"] as? String, let n = input["new_string"] as? String { edit = ClaudeEditDiff(old: o, new: n) }
        case "NotebookEdit":
            verb = "編集"; icon = "pencil"; filePath = str("notebook_path"); title = base(filePath)
        case "Grep":
            verb = "検索"; icon = "magnifyingglass"
            title = (str("pattern") ?? "") + (str("path").map { " (\(base($0)))" } ?? "")
        case "Glob":
            verb = "ファイル検索"; icon = "doc.text.magnifyingglass"; title = str("pattern") ?? ""
        case "WebFetch":
            verb = "Web"; icon = "globe"; title = str("url").flatMap { URL(string: $0)?.host } ?? (str("url") ?? "")
        case "WebSearch":
            verb = "Web 検索"; icon = "globe"; title = str("query") ?? ""
        case "Task", "Agent":
            verb = "サブエージェント"; icon = "person.2"; title = str("description") ?? ""
        case "TodoWrite":
            verb = "ToDo"; icon = "checklist"; title = "更新"
        case "Skill":
            verb = "スキル"; icon = "sparkles"; title = str("skill") ?? str("command") ?? ""
        case "ToolSearch":
            verb = "道具の検索"; icon = "magnifyingglass"; title = str("query") ?? ""
        case "AskUserQuestion":
            verb = "質問"; icon = "questionmark.bubble"; title = ""
        case "ExitPlanMode":
            verb = "計画"; icon = "list.bullet.clipboard"; title = ""
        default:
            if name.hasPrefix("mcp__") {
                // mcp__server__tool → 種類は tool、要約は server
                let comps = name.dropFirst(5).components(separatedBy: "__")
                verb = comps.last ?? name
                icon = "puzzlepiece.extension"
                title = comps.count > 1 ? comps[0] : ""
            }
            if title.isEmpty, let first = input.sorted(by: { $0.key < $1.key }).first(where: { $0.value is String })?.value as? String {
                title = firstLine(first)
            }
        }
        return ClaudeToolCall(id: id, name: name, verb: verb, icon: icon, title: clip(title, 80),
                              input: prettyInput(name: name, input: input), edit: edit, filePath: filePath)
    }

    /// 開いたときの入力の見せ方。Bash はコマンドそのもの、TodoWrite は ToDo の一覧、それ以外は整形した JSON。
    static func prettyInput(name: String, input: [String: Any]) -> String {
        if name == "Bash", let c = input["command"] as? String { return c }
        if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            return todos.map { t in
                let mark: String
                switch t["status"] as? String {
                case "completed": mark = "☑︎"
                case "in_progress": mark = "▶︎"
                default: mark = "☐"
                }
                return "\(mark) \(t["content"] as? String ?? "")"
            }.joined(separator: "\n")
        }
        if (name == "Edit" || name == "MultiEdit"), let p = input["file_path"] as? String { return p }
        if name == "Write", let p = input["file_path"] as? String {
            let content = input["content"] as? String ?? ""
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(p)(\(lines) 行)\n\n" + clip(content, 4000)
        }
        if input.isEmpty { return "" }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return clip(s, 6000)
    }

    static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    static func duration(ms: Int) -> String {
        let s = ms / 1000
        return s < 60 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒"
    }
}
