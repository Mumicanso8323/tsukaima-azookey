import SwiftUI

/// 時系列表示: 本文・thinking(折りたたみ)・ツール呼び出しと結果(要約→展開)・エラー。
/// 実機の不具合対応:
///   - mcp__tsukaima__reply の tool_use は「Claude の返事」として本文と同じ扱いで大きく出す(その tool_result は隠す)。
///   - data.source=="meta" の user・`<local-command-…>`/`<command-…>` タグ入りの user・system の
///     informational は既定で隠す(showDetails トグルでだけ出す)。ローカルコマンドの結果(「Set effort
///     level to medium」など)はトグルに関係なく常に 1 行の控えめな表示。
struct ClaudeTimelineView: View {
    let events: [ClaudeEvent]
    var showDetails: Bool = false

    /// mcp__tsukaima__reply の tool_use.id(その tool_result は表示しない)
    private var replyToolUseIDs: Set<String> {
        Set(events.filter(\.isReplyToolUse).compactMap(\.toolUseID))
    }

    private var visibleEvents: [ClaudeEvent] {
        let replyIDs = replyToolUseIDs
        return events.filter { ev in
            if ev.kind == .toolResult, let rid = ev.toolResultForID, replyIDs.contains(rid) { return false }
            if ev.isHiddenByDefault && !showDetails { return false }
            return true
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleEvents) { ev in
                        ClaudeEventRow(event: ev).id(ev.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("claude.timeline")
            // 履歴を下へ引っぱるとキーボードをしまう(公式アプリと同じ。本人の明示的な操作でだけ外れる)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: visibleEvents.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct ClaudeEventRow: View {
    let event: ClaudeEvent

    var body: some View {
        switch event.kind {
        case .user:
            bubble(text: event.text, alignment: .trailing,
                  tint: event.isChannelVoice ? Color.purple.opacity(0.18) : Color.accentColor.opacity(0.18))
        case .text:
            bubble(text: event.text, alignment: .leading, tint: Color.gray.opacity(0.15))
        case .thinking:
            CollapsibleBlock(title: "thinking", icon: "brain", tint: .purple) {
                Text(event.text.isEmpty ? "(考え中)" : event.text)
                    .font(.footnote.monospaced())
            }
        case .toolUse:
            if event.isReplyToolUse, let reply = event.replyText {
                // Claude の返事そのもの(本体は mcp__tsukaima__reply ツールでしか返事しない)。
                // ツール枠ではなく、text と同じ「Claude の返事」として本文を大きく出す。
                bubble(text: reply, alignment: .leading, tint: Color.gray.opacity(0.15))
            } else {
                CollapsibleBlock(title: event.toolName ?? "ツール呼び出し", icon: "wrench.and.screwdriver", tint: .orange) {
                    Text(event.toolInputSummary ?? "(入力なし)")
                        .font(.footnote.monospaced())
                }
            }
        case .toolResult:
            CollapsibleBlock(title: "結果: \(event.toolName ?? "ツール")", icon: "checkmark.seal", tint: .green) {
                Text(event.toolOutputSummary ?? "(出力なし)")
                    .font(.footnote.monospaced())
            }
        case .system:
            if event.isLocalCommandResult {
                Label(event.text, systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(event.text).font(.caption).foregroundStyle(.secondary)
            }
        case .result:
            Label(event.text.isEmpty ? "完了" : event.text, systemImage: "flag.checkered")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        case .error:
            Label(event.text.isEmpty ? "エラーが発生しました" : event.text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func bubble(text: String, alignment: HorizontalAlignment, tint: Color) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 24) }
            Text(text)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(tint, in: RoundedRectangle(cornerRadius: 12))
            if alignment == .leading { Spacer(minLength: 24) }
        }
    }
}

/// thinking・ツール呼び出し/結果を要約1行で見せ、開けば全文。
private struct CollapsibleBlock<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: () -> Content
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tint)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
