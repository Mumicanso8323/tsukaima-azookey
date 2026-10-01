import SwiftUI

/// いまのターン(本人の最後の発言から後)のツール実行の集計(純ロジック)。Claude Code 自身の
/// 「思考中…(3件のツールを実行中…)」と同じ 1 行を出すためのもの。Bash の出力などは見せない。
struct ClaudeToolActivity: Equatable {
    struct Item: Equatable {
        enum State: Equatable { case running, succeeded, failed }
        let id: String
        let name: String
        var state: State
    }

    var items: [Item] = []
    /// 本人の発言の後、result/error がまだ来ていない(= ターンが開いている)
    var turnOpen = false

    var running: Int { items.filter { $0.state == .running }.count }
    var succeeded: Int { items.filter { $0.state == .succeeded }.count }
    var failed: Int { items.filter { $0.state == .failed }.count }

    /// 最後の本人の発言(meta・生タグは数えない)から後の tool_use/tool_result を集める。
    /// mcp__tsukaima__reply は「返事」なのでツールに数えない。
    static func reduce(_ events: [ClaudeEvent]) -> ClaudeToolActivity {
        var start = 0
        for (i, ev) in events.enumerated() where ev.kind == .user && !ev.isHiddenByDefault {
            start = i
        }
        var out = ClaudeToolActivity()
        guard !events.isEmpty else { return out }
        out.turnOpen = events[start].kind == .user
        var index: [String: Int] = [:]
        for ev in events[start...] {
            switch ev.kind {
            case .toolUse:
                guard !ev.isReplyToolUse else { continue }
                let id = ev.toolUseID ?? "seq-\(ev.seq)"
                index[id] = out.items.count
                out.items.append(Item(id: id, name: ev.toolName ?? "ツール", state: .running))
            case .toolResult:
                guard let rid = ev.toolResultForID, let i = index[rid] else { continue }
                out.items[i].state = ev.isToolError ? .failed : .succeeded
            case .result, .error:
                out.turnOpen = false
            default:
                break
            }
        }
        return out
    }

    /// 1 行の文言。思考中(busy)かどうかは status から渡す。
    /// 空文字のときも表示側は高さを変えない(レイアウトが跳ねてカーソルを奪わないように)。
    func line(busy: Bool) -> String {
        if busy && (turnOpen || items.isEmpty || running > 0) {
            return running > 0 ? "思考中…(\(running)件のツールを実行中…)" : "思考中…"
        }
        let done = succeeded + failed
        guard done > 0 || running > 0 else { return "" }
        var parts: [String] = []
        if succeeded > 0 || failed == 0 { parts.append("\(succeeded)件のツールが成功") }
        if failed > 0 { parts.append("\(failed)件が失敗") }
        if running > 0 { parts.append("\(running)件が未完了") }
        return "(" + parts.joined(separator: "、") + ")"
    }
}

/// 入力欄の上に出す 1 行の状態表示(高さ固定・小さい字・その場で書き換わる)。タップで各ツールの内訳を開ける。
struct ClaudeToolStatusLine: View {
    let activity: ClaudeToolActivity
    let busy: Bool
    @State private var expanded = false

    static let lineHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini)
                }
                Text(activity.line(busy: busy))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.identity)
                Spacer(minLength: 0)
                if !activity.items.isEmpty {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: Self.lineHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !activity.items.isEmpty else { return }
                expanded.toggle()
            }
            .accessibilityIdentifier("claude.toolStatus")
            if expanded {
                ForEach(activity.items, id: \.id) { item in
                    HStack(spacing: 4) {
                        Image(systemName: icon(item.state))
                            .font(.system(size: 9))
                            .foregroundStyle(color(item.state))
                        Text(item.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .animation(nil, value: activity)
    }

    private func icon(_ s: ClaudeToolActivity.Item.State) -> String {
        switch s {
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.circle"
        }
    }

    private func color(_ s: ClaudeToolActivity.Item.State) -> Color {
        switch s {
        case .running: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }
}
