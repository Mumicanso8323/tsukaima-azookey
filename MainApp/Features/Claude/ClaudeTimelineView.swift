import SwiftUI
import UIKit

/// 会話の表示(公式の Claude アプリに合わせる):
///   - 一覧は List(UICollectionView)。ScrollView + LazyVStack + scrollTo の組み合わせは、SwiftUI の描き直しが
///     終わらなくなる停止を起こした(2026-10-05 CI でメインスレッドが 80〜110 秒止まるのを確認。docs/claude-tab-hang.md)。
///   - 本人の発言は右の吹き出し、Claude の返事は吹き出し無しの Markdown。
///   - ツール呼び出しと thinking は 1 行の「作業のまとまり」に畳む(ClaudeActivityRow)。生の出力は開いたときだけ。
///   - 上へ読み返している間は、新着が来ても下へ飛ばない。右下の「↓」で最下部へ戻る。
///   - 作業中は最下部に「作業中」の行(最新のツールの 1 行)を出す。
/// 長い会話でも重くしない: 項目は ClaudeSession が q の上でまとめて作り、各行は Equatable で変わった行だけ描き直す。
struct ClaudeTimelineView: View {
    let items: [ClaudeItem]
    let busy: Bool
    /// 選び直したセッション・接続の直後の一括再送を受け終えた(最初に最下部へ移す合図)
    let historyLoaded: Bool
    var onResend: (String) -> Void = { _ in }

    @State private var atBottom = true
    /// 最下部へのスクロールの要求(数が変わるたびに 1 回動かす)。実際に動かすのは BottomScroller。
    @State private var bottomRequest = 0
    @State private var unseen = false

    private var lastSignature: String {
        guard let last = items.last else { return "" }
        switch last {
        case .assistant(let id, let md): return "\(id):\(md.utf8.count)"  // utf8.count は O(1)(count は文字数えで O(n))
        case .activity(let a):
            var done = 0
            for case .tool(let c) in a.steps where c.hasResult { done += 1 }
            return "\(a.id):\(a.steps.count):\(done)"
        default: return last.id
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if items.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                let lastID = busy ? items.last?.id : nil
                ForEach(items) { item in
                    ClaudeItemRow(item: item, live: item.id == lastID, onResend: onResend)
                        .equatable()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
                }
                if busy {
                    ClaudeWorkingRow(latest: latestActivityTitle)
                        .id("working")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
                }
                Color.clear.frame(height: 1).id("bottom")
                    .modifier(BottomMarkerTracker(atBottom: $atBottom, unseen: $unseen))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("claude.timeline")
            // 履歴を下へ引っぱるとキーボードをしまう(公式アプリと同じ。ただし物理キーボード接続中は閉じない)
            .hardwareAwareScrollDismissesKeyboard()
            .modifier(BottomTracker(atBottom: $atBottom, unseen: $unseen))
            .modifier(BottomScroller(request: bottomRequest, proxy: proxy))
            .modifier(ClaudeScrollProbeModifier())
            .onChange(of: lastSignature) { _, _ in
                // 自分が送った文は、どこを読んでいても最下部へ戻して見せる(公式アプリと同じ)
                if case .user = items.last {
                    atBottom = true
                    unseen = false
                    bottomRequest &+= 1
                    return
                }
                // 下を見ているときだけ追う。上を読んでいるときは「新着あり」の印だけ付ける
                if atBottom {
                    bottomRequest &+= 1
                } else {
                    unseen = true
                }
            }
            // キーボードが出て一覧が縮んでも、最下部を見ていたなら最下部のままにする
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if atBottom { bottomRequest &+= 1 }
            }
            .onChange(of: busy) { _, _ in
                if atBottom { bottomRequest &+= 1 }
            }
            .onChange(of: historyLoaded) { _, loaded in
                if loaded { bottomRequest &+= 1; atBottom = true }
            }
            .onAppear { bottomRequest &+= 1 }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { bottomRequest &+= 1 }
                        unseen = false
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: Circle())
                            .overlay(alignment: .topTrailing) {
                                if unseen { Circle().fill(Color.accentColor).frame(width: 10, height: 10) }
                            }
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .accessibilityLabel("最新へ移動")
                    .accessibilityIdentifier("claude.scrollToBottom")
                    .transition(.opacity)
                }
            }
        }
    }

    private var latestActivityTitle: String? {
        for item in items.reversed() {
            if case .activity(let a) = item { return a.hasPending ? a.latestTitle : nil }
            if case .assistant = item { return nil }
        }
        return nil
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(historyLoaded ? "まだ会話がありません" : "読み込んでいます…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// 最下部にいるかを、スクロールの位置から正確に判定する(iOS 18 以降。それより前は最下部の印の出入りで判定)
/// iOS 17 用: 最下部の目印が見えているかで atBottom を決める。
/// iOS 18 以降は BottomTracker(スクロール量)だけで決める。両方が atBottom を書くと、レイアウトの途中で食い違って
/// 描き直しが終わらなくなる(2026-10-05 に CI で、メインスレッドが 80〜110 秒 SwiftUI の更新から出てこない停止を確認した)。
private struct BottomMarkerTracker: ViewModifier {
    @Binding var atBottom: Bool
    @Binding var unseen: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
            content
                .onAppear { atBottom = true; unseen = false }
                .onDisappear { atBottom = false }
        }
    }
}

/// 最下部へのスクロールを実際に行う。
/// iOS 18 以降は ScrollPosition の scrollTo(edge: .bottom)(位置で動かす)。ScrollViewReader.scrollTo は List では
/// 行(index path)を指すため、新着で行の数が変わる途中に呼ぶと UIKit の検査
/// (-[UICollectionView _validateScrollingTargetIndexPath:])が例外を投げてアプリが落ちた(2026-10-05 CI のクラッシュ報告)。
/// iOS 17 は ScrollPosition が無いので、従来の scrollTo のまま。
private struct BottomScroller: ViewModifier {
    let request: Int
    let proxy: ScrollViewProxy

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(BottomScrollerByPosition(request: request))
        } else {
            content.onChange(of: request) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

@available(iOS 18.0, *)
private struct BottomScrollerByPosition: ViewModifier {
    let request: Int
    @State private var position = ScrollPosition(edge: .bottom)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: request) { _, _ in
                position.scrollTo(edge: .bottom)
            }
    }
}

/// 「最下部から離れた」は、本人がスクロールしている間だけ認める。キーボードが出て一覧が縮んだ・行が伸びた、
/// のような本人の操作でない変化で離れたと読むと、追従が止まって、送った文や新着が画面の外に出てしまう。
private struct BottomTracker: ViewModifier {
    @Binding var atBottom: Bool
    @Binding var unseen: Bool
    @State private var userScrolling = false

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, now in
                if now {
                    if !atBottom { atBottom = true }
                    unseen = false
                } else if userScrolling, atBottom {
                    atBottom = false
                }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
        } else {
            content
        }
    }
}

// MARK: - 行

private struct ClaudeItemRow: View, Equatable {
    let item: ClaudeItem
    /// いま作業中の最後の項目(作業中の印を出す)
    let live: Bool
    let onResend: (String) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.item == b.item && a.live == b.live }

    var body: some View {
        switch item {
        case .user(_, let text, let attachments, let voice):
            ClaudeUserBubble(text: text, attachments: attachments, voice: voice, onResend: onResend)
        case .assistant(_, let markdown):
            ClaudeAssistantMessage(markdown: markdown)
                // 流れている最中の返事は文字の選択を外す(選択できる Text は配置が重く、更新のたびに主スレッドが詰まる)。
                // 終われば選べる。いつでも長押しの「テキストを選択」で選べる。
                .environment(\.claudeTextSelectable, !live)
        case .activity(let activity):
            ClaudeActivityRow(activity: activity, live: live)
        case .artifact(_, let path, let kind, let edited):
            ClaudeArtifactCard(path: path, kind: kind, edited: edited)
        case .note(_, let text, let icon):
            Label(text, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .center)
        case .error(_, let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

/// 本人の発言(右寄せの吹き出し)。長押しでコピー・再送・テキストを選択。
private struct ClaudeUserBubble: View {
    let text: String
    let attachments: [ClaudeAttachmentRef]
    let voice: Bool
    let onResend: (String) -> Void
    @EnvironmentObject private var router: ClaudeViewerRouter

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let images = attachments.filter(\.isImage)
            let files = attachments.filter { !$0.isImage }
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images) { a in
                        Button {
                            router.openImage(a.path)
                        } label: {
                            ClaudeRemoteImage(source: a.path, maxPixel: 400)
                                .frame(width: images.count == 1 ? 180 : 100, height: images.count == 1 ? 180 : 100)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("添付画像 \(a.name)")
                        .accessibilityIdentifier("claude.attachment.image")
                    }
                }
            }
            ForEach(files) { a in
                Button {
                    router.openFile(a.path)
                } label: {
                    Label(a.name, systemImage: ClaudeFileKind(path: a.path).icon)
                        .font(.footnote)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if !text.isEmpty {
                HStack(alignment: .bottom, spacing: 4) {
                    if voice {
                        Image(systemName: "mic.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                        .contextMenu {
                            Button { UIPasteboard.general.string = text } label: { Label("コピー", systemImage: "doc.on.doc") }
                            Button { onResend(text) } label: { Label("もう一度送る", systemImage: "arrow.clockwise") }
                            Button { router.selectText(text) } label: { Label("テキストを選択", systemImage: "selection.pin.in.out") }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }
}

/// Claude の返事(吹き出し無し・Markdown)。下にコピーの小さなボタン。長押しでコピー・テキストを選択・共有。
private struct ClaudeAssistantMessage: View {
    let markdown: String
    @EnvironmentObject private var router: ClaudeViewerRouter
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClaudeMarkdownView(blocks: ClaudeMarkdownCache.blocks(markdown))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button { UIPasteboard.general.string = markdown } label: { Label("コピー", systemImage: "doc.on.doc") }
                    Button { router.selectText(markdown) } label: { Label("テキストを選択", systemImage: "selection.pin.in.out") }
                    ShareLink(item: markdown) { Label("共有", systemImage: "square.and.arrow.up") }
                }
            HStack(spacing: 14) {
                Button {
                    UIPasteboard.general.string = markdown
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "コピーしました" : "返事をコピー")
                .accessibilityIdentifier("claude.copyMessage")
            }
        }
    }
}

/// 解析済みの Markdown を覚えておく(同じ返事を描き直すたびに解析し直さない)
@MainActor
enum ClaudeMarkdownCache {
    private static var cache: [String: [MDBlock]] = [:]
    private static var order: [String] = []

    static func blocks(_ markdown: String) -> [MDBlock] {
        if let hit = cache[markdown] { return hit }
        let parsed = ClaudeMarkdown.parse(markdown)
        cache[markdown] = parsed
        order.append(markdown)
        if order.count > 300 {
            cache.removeValue(forKey: order.removeFirst())
        }
        return parsed
    }
}

/// 作業のまとまり(ツール呼び出しと thinking)を 1 行に。タップで中の一覧、さらに各行のタップで入力と出力。
private struct ClaudeActivityRow: View {
    let activity: ClaudeActivity
    let live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if live && activity.hasPending && !ClaudeConfig.isMock {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: activity.icon)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                    }
                    Text(activity.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if activity.errorCount > 0 {
                        Text("失敗 \(activity.errorCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("claude.activity")
            .accessibilityValue(expanded ? "開いている" : "閉じている")

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(activity.steps) { step in
                        switch step {
                        case .tool(let call):
                            ClaudeToolCallRow(call: call, live: live)
                        case .thinking(_, let text):
                            ClaudeThinkingRow(text: text)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(.separator)).frame(width: 1)
                }
                .padding(.leading, 8)
                .padding(.bottom, 4)
            }
        }
    }
}

private struct ClaudeToolCallRow: View {
    let call: ClaudeToolCall
    let live: Bool
    @State private var expanded = false
    @State private var showAllOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Image(systemName: call.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(call.verb).font(.footnote.weight(.medium))
                    Text(call.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("claude.toolCall")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let edit = call.edit {
                        ClaudeDiffView(edit: edit)
                    } else if !call.input.isEmpty {
                        codeBox(call.input, label: "入力")
                    }
                    if let out = call.output {
                        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
                        let clipped = !showAllOutput && lines.count > 30
                        codeBox(clipped ? lines.prefix(30).joined(separator: "\n") : out,
                                label: call.isError ? "エラー" : (call.truncated ? "出力(サーバーで 4000 字に切ってあります)" : "出力"),
                                tint: call.isError ? .red : nil)
                        if clipped {
                            Button("すべて表示(\(lines.count) 行)") { showAllOutput = true }
                                .font(.caption)
                        }
                    } else if !call.hasResult {
                        Text(live ? "実行中…" : "結果なし").font(.caption).foregroundStyle(.secondary)
                    }
                    if let path = call.filePath {
                        ClaudeOpenFileButton(path: path)
                    }
                }
                .padding(.leading, 24)
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if call.isError {
            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        } else if call.hasResult {
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        } else if live && !ClaudeConfig.isMock {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "circle.dotted").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func codeBox(_ text: String, label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(tint ?? .secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(tint ?? .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            .frame(maxHeight: 320)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ClaudeOpenFileButton: View {
    let path: String
    @EnvironmentObject private var router: ClaudeViewerRouter

    var body: some View {
        Button {
            router.openFile(path)
        } label: {
            Label((path as NSString).lastPathComponent + " を開く", systemImage: "arrow.up.forward.square")
                .font(.caption)
        }
    }
}

/// Edit の差分(消した行は赤、足した行は緑)
private struct ClaudeDiffView: View {
    let edit: ClaudeEditDiff

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(edit.old.split(separator: "\n", omittingEmptySubsequences: false).prefix(80).enumerated()), id: \.offset) { _, line in
                    Text("- " + line)
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                }
                ForEach(Array(edit.new.split(separator: "\n", omittingEmptySubsequences: false).prefix(80).enumerated()), id: \.offset) { _, line in
                    Text("+ " + line)
                        .foregroundStyle(Color.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.08))
                }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
            .padding(8)
        }
        .frame(maxHeight: 360)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ClaudeThinkingRow: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain").font(.caption).foregroundStyle(.secondary).frame(width: 16)
                    Text("考えたこと").font(.footnote.weight(.medium))
                    Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            }
        }
    }
}

/// Claude が作った/直したファイルのカード。押すとアプリ内で開く。
private struct ClaudeArtifactCard: View {
    let path: String
    let kind: ClaudeFileKind
    let edited: Bool
    @EnvironmentObject private var router: ClaudeViewerRouter

    var body: some View {
        Button {
            router.openFile(path)
        } label: {
            HStack(spacing: 12) {
                if kind == .image {
                    ClaudeRemoteImage(source: path, maxPixel: 200)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: kind.icon)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text((edited ? "編集 · " : "作成 · ") + ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("claude.artifact")
        .accessibilityLabel("成果物 \((path as NSString).lastPathComponent) を開く")
    }
}

/// 作業中の行(最下部)。最新のツールの 1 行を添える。
private struct ClaudeWorkingRow: View {
    let latest: String?
    @State private var phase = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(Color.orange)
                .scaleEffect(phase ? 1.15 : 0.85)
                .opacity(phase ? 1 : 0.6)
                // 終わらないアニメーションがあると、UI テストが「画面が静止するのを待つ」で時間切れになる。偽サーバーのときは動かさない
                .animation(ClaudeConfig.isMock ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: phase)
                .onAppear { phase = !ClaudeConfig.isMock }
            Text(latest ?? "考えています…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("claude.working")
    }
}

// MARK: - UI テスト用の見張り(ClaudeConfig.isMock のときだけ動く)

/// 一覧のスクロール位置(上端・下端からの距離)と、本人の操作でない大きな跳び(一番上へ・一番下へ)の回数。
/// 送信の直後に最下部へ戻すのは仕様なので、送信を含むテストでは jumpBottom を見ない。
/// 本人の「IME を開くと一番上まで飛ぶ」「意図しない時に一番下まで飛ぶ」を UI テストで捕まえるため。本番では作らない。
@MainActor
final class ClaudeScrollProbe: ObservableObject {
    static let shared = ClaudeScrollProbe()
    @Published private(set) var fromTop: Int = -1
    @Published private(set) var fromBottom: Int = -1
    @Published private(set) var jumpsToTop = 0
    @Published private(set) var jumpsToBottom = 0
    var userScrolling = false

    func update(top: CGFloat, bottom: CGFloat) {
        let t = Int(top), b = Int(bottom)
        if fromTop >= 0, !userScrolling {
            if fromTop > 600, t < 40 { jumpsToTop += 1 }
            if fromBottom > 300, b < 60 { jumpsToBottom += 1 }
        }
        fromTop = t
        fromBottom = b
    }

    var summary: String { "top=\(fromTop) bottom=\(fromBottom) jumpTop=\(jumpsToTop) jumpBottom=\(jumpsToBottom)" }
}

private struct ClaudeScrollProbeModifier: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if ClaudeConfig.isMock, #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: [CGFloat].self) { geo in
                    [geo.visibleRect.minY, geo.contentSize.height - geo.visibleRect.maxY]
                } action: { _, v in
                    ClaudeScrollProbe.shared.update(top: v[0], bottom: v[1])
                }
                .onScrollPhaseChange { _, phase in
                    ClaudeScrollProbe.shared.userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                }
        } else {
            content
        }
    }
}
