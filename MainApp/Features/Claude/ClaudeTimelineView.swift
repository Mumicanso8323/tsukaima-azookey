import SwiftUI
import UIKit

/// 時系列表示: 本文・thinking(折りたたみ)・エラー。ツール呼び出し/結果の枠は既定で出さない
/// (入力欄の上の 1 行 ClaudeToolStatusLine に集計して出す。「詳細を表示」トグルでだけ枠を出す)。
/// 実機の不具合対応:
///   - mcp__tsukaima__reply の tool_use は「Claude の返事」として本文と同じ扱いで大きく出す(その tool_result は隠す)。
///   - data.source=="meta" の user・`<local-command-…>`/`<command-…>` タグ入りの user・system の
///     informational は既定で隠す(showDetails トグルでだけ出す)。ローカルコマンドの結果(「Set effort
///     level to medium」など)はトグルに関係なく常に 1 行の控えめな表示。
/// 新着での自動スクロールは「最下部にいたときだけ」(読み返し中に戻さない)。物理キーボードのスクロールは
/// ClaudeTimelineScroller 経由(入力欄にカーソルを置いたまま効く)。
struct ClaudeTimelineView: View {
    let events: [ClaudeEvent]
    var showDetails: Bool = false
    var scroller: ClaudeTimelineScroller?

    /// mcp__tsukaima__reply の tool_use.id(その tool_result は表示しない)
    private var replyToolUseIDs: Set<String> {
        Set(events.filter(\.isReplyToolUse).compactMap(\.toolUseID))
    }

    private var visibleEvents: [ClaudeEvent] {
        let replyIDs = replyToolUseIDs
        return events.filter { ev in
            if ev.kind == .toolResult, let rid = ev.toolResultForID, replyIDs.contains(rid) { return false }
            if ev.isHiddenByDefault && !showDetails { return false }
            if !showDetails, ev.kind == .toolResult || (ev.kind == .toolUse && !ev.isReplyToolUse) { return false }
            return true
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // 包んでいる UIScrollView を見つけて scroller に渡す(高さ 0)
                    ClaudeScrollViewFinder(scroller: scroller).frame(height: 0)
                    ForEach(visibleEvents) { ev in
                        ClaudeEventRow(event: ev, turnText: { turnText(around: ev) }).id(ev.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            // タイムラインのスクロールでキーボードを閉じない(読み返しでカーソルが外れないように。閉じるのは Esc/ボタン)
            .scrollDismissesKeyboard(.never)
            .onChange(of: visibleEvents.count) { _, _ in
                guard scroller?.isNearBottom ?? true else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// 「このターンをコピー」用: その出来事を含むターン(本人の発言から次の本人の発言の手前まで)の本文
    private func turnText(around ev: ClaudeEvent) -> String {
        guard let i = events.firstIndex(where: { $0.id == ev.id }) else { return ev.copyText }
        var start = i
        while start > 0, !(events[start].kind == .user && !events[start].isHiddenByDefault) { start -= 1 }
        var end = i + 1
        while end < events.count, !(events[end].kind == .user && !events[end].isHiddenByDefault) { end += 1 }
        return events[start..<end].compactMap { e in
            switch e.kind {
            case .user: "> " + e.text
            case .text: e.text
            case .toolUse: e.replyText
            default: nil
            }
        }.joined(separator: "\n\n")
    }
}

/// 物理キーボードから履歴をスクロールするための取っ手(UIScrollView を直接動かす。SwiftUI の ScrollView は
/// iOS 17 では相対スクロールの API が無い)。ClaudeTabView が持ち、タイムラインと入力欄の両方に渡す。
@MainActor
final class ClaudeTimelineScroller {
    weak var scrollView: UIScrollView?

    /// 最下部(数行分の余裕つき)にいるか。新着で追従するかの判定
    var isNearBottom: Bool {
        guard let sv = scrollView else { return true }
        let bottom = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
        return sv.contentOffset.y >= bottom - 40
    }

    func scroll(lines: Int) {
        move(by: CGFloat(lines) * UIFont.preferredFont(forTextStyle: .body).lineHeight)
    }

    func scroll(pages: Int) {
        guard let sv = scrollView else { return }
        move(by: CGFloat(pages) * sv.bounds.height * 0.9)
    }

    func scrollToTop() {
        guard let sv = scrollView else { return }
        sv.setContentOffset(CGPoint(x: 0, y: -sv.adjustedContentInset.top), animated: true)
    }

    func scrollToBottom() {
        guard let sv = scrollView else { return }
        sv.setContentOffset(CGPoint(x: 0, y: maxOffset(sv)), animated: true)
    }

    private func maxOffset(_ sv: UIScrollView) -> CGFloat {
        max(sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom, -sv.adjustedContentInset.top)
    }

    private func move(by dy: CGFloat) {
        guard let sv = scrollView else { return }
        let y = min(max(sv.contentOffset.y + dy, -sv.adjustedContentInset.top), maxOffset(sv))
        sv.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    /// ComposerKeyBinding のスクロール系を受ける。スクロール以外は false
    func handle(_ binding: ComposerKeyBinding) -> Bool {
        switch binding {
        case .scrollLinesUp: scroll(lines: -3)
        case .scrollLinesDown: scroll(lines: 3)
        case .scrollPageUp: scroll(pages: -1)
        case .scrollPageDown: scroll(pages: 1)
        case .scrollTop: scrollToTop()
        case .scrollBottom: scrollToBottom()
        default: return false
        }
        return true
    }
}

/// ScrollView の中に置いて、包んでいる UIScrollView を見つける(高さ 0 の UIView)
private struct ClaudeScrollViewFinder: UIViewRepresentable {
    let scroller: ClaudeTimelineScroller?

    final class FinderView: UIView {
        var scroller: ClaudeTimelineScroller?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var v: UIView? = superview
            while let cur = v, !(cur is UIScrollView) { v = cur.superview }
            scroller?.scrollView = v as? UIScrollView
        }
    }

    func makeUIView(context: Context) -> FinderView {
        let v = FinderView()
        v.scroller = scroller
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: FinderView, context: Context) {
        uiView.scroller = scroller
    }
}

private struct ClaudeEventRow: View {
    let event: ClaudeEvent
    /// 長押しメニューを開いたときだけ計算する(行ごとに毎回計算すると 4000 件で重い)
    let turnText: () -> String

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
                    .textSelection(.enabled)
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
                        .textSelection(.enabled)
                }
            }
        case .toolResult:
            CollapsibleBlock(title: "結果: \(event.toolName ?? "ツール")", icon: event.isToolError ? "xmark.seal" : "checkmark.seal",
                             tint: event.isToolError ? .red : .green) {
                Text(event.toolOutputSummary ?? "(出力なし)")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
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

    /// 本文の吹き出し。長押しで「コピー」「このターンをコピー」、本文は選択可。コードブロック(```)は右上に小さなコピー。
    private func bubble(text: String, alignment: HorizontalAlignment, tint: Color) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ClaudeMessageSegment.split(text).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let t):
                        Text(t).font(.body).textSelection(.enabled)
                    case .code(let c):
                        ZStack(alignment: .topTrailing) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(c).font(.footnote.monospaced()).textSelection(.enabled)
                                    .padding(8).padding(.trailing, 22)
                            }
                            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            Button {
                                UIPasteboard.general.string = c
                            } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .padding(5)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("コードをコピー")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint, in: RoundedRectangle(cornerRadius: 12))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                }
                Button {
                    UIPasteboard.general.string = turnText()
                } label: {
                    Label("このターンをコピー", systemImage: "doc.on.doc.fill")
                }
            }
            if alignment == .leading { Spacer(minLength: 24) }
        }
    }
}

/// 本文を「地の文」と「``` で囲まれたコード」に分ける(純ロジック・テスト対象)
enum ClaudeMessageSegment: Equatable {
    case text(String)
    case code(String)

    static func split(_ s: String) -> [ClaudeMessageSegment] {
        var out: [ClaudeMessageSegment] = []
        var rest = Substring(s)
        while let open = rest.range(of: "```") {
            let before = rest[..<open.lowerBound]
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(String(before))) }
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "```") else {
                out.append(.code(Self.stripLang(String(afterOpen))))
                return out
            }
            out.append(.code(Self.stripLang(String(afterOpen[..<close.lowerBound]))))
            rest = afterOpen[close.upperBound...]
        }
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || out.isEmpty { out.append(.text(String(rest))) }
        return out
    }

    /// 先頭行の言語名(```swift など)は落とす
    private static func stripLang(_ code: String) -> String {
        guard let nl = code.firstIndex(of: "\n") else { return code.trimmingCharacters(in: .whitespacesAndNewlines) }
        let first = code[..<nl]
        let body = first.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" }) ? code[code.index(after: nl)...] : code[...]
        return String(body).trimmingCharacters(in: .newlines)
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
