import SwiftUI

/// 最新の返事 1 件を大きく出すカード(DEC-9 / DEC-10)。240 字までは全部、超えたら先頭 240 字+「全文」(同じ画面のシート)。
/// 履歴は持たない(Claude タブの役目)。
struct BlindReplyCard: View {
    @ObservedObject var host: BlindLinkHost
    @ObservedObject var store: BlindReplyStore
    let onOpenClaude: () -> Void
    @State private var showFull = false
    /// このカードが実際に画面に見えているか(見えていない BlindScreen が未読を消さないように)
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stateLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("blind.reply.state")

            if let reply = store.last {
                let preview = BlindReplyLayout.preview(reply.text)
                Text(preview.displayText)
                    .font(.title2)
                    .foregroundStyle(reply.question ? Color.orange : Color.primary)
                    .opacity(isStale(reply) ? 0.55 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("blind.reply.text")
                if store.replacedUnread > 0 {
                    Text("未読 +\(store.replacedUnread)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("blind.reply.unread")
                }
                if preview.isTruncated {
                    Button("全文") { showFull = true }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("blind.reply.more")
                }
            } else {
                Text("返事はまだありません")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("blind.reply.empty")
            }

            Button("Claude タブで開く", action: onOpenClaude)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("blind.reply.openClaude")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blind.reply.card")
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: store.unread) { _, unread in
            // この画面が実際に見えている間に届いた返事だけ「見た」扱い(見ていない分は「未読 +n」に残す)
            if unread > 0, visible { store.markSeen() }
        }
        .sheet(isPresented: $showFull) {
            NavigationStack {
                ScrollView {
                    Text(store.last?.text ?? "")
                        .font(.title3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("blind.reply.full")
                }
                .navigationTitle("全文")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("閉じる") { showFull = false }
                            .accessibilityIdentifier("blind.reply.full.close")
                    }
                }
            }
        }
    }

    /// 再接続で届いた 30 分より古い返事は薄く出す(振動もしない)。
    private func isStale(_ reply: BlindReply) -> Bool {
        reply.replay && Date().timeIntervalSince1970 - reply.at > BlindHapticDecision.replayMaxAgeSeconds
    }

    /// 状態の 1 行: Claude 側の作業中(path.busy)・宛先の名前(サーバーが送ったまま)・溜めた返事の件数。
    private var stateLine: String {
        guard host.isProto2 else {
            return host.proto == 1 ? "状態: 古いサーバー(声のみ)" : "状態: 確認中"
        }
        guard let path = host.path else { return "状態: 確認中" }
        var parts: [String] = []
        parts.append(path.ok ? (path.busy ? "作業中" : "待機中") : "つながっていない")
        if let name = path.name, !name.isEmpty { parts.append(name) }
        if host.heldCount > 0 { parts.append("溜めた返事 \(host.heldCount)") }
        return "状態: " + parts.joined(separator: " / ")
    }
}

/// UI テスト専用(--blind-mock-replies)。本物のサーバーの代わりに、同じ受信経路へ返事を流し、結果を数字で見せる。
struct BlindMockControls: View {
    @ObservedObject var host: BlindLinkHost

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("返事") { host.sendMockReply() }
                    .accessibilityIdentifier("blind.mock.reply")
                Button("長い返事") { host.sendMockReply(text: BlindMockControls.longText) }
                    .accessibilityIdentifier("blind.mock.reply.long")
                Button("同じ返事") { host.sendMockReply(repeatLast: true) }
                    .accessibilityIdentifier("blind.mock.reply.dup")
            }
            HStack(spacing: 8) {
                Button("遅れて返事") { host.delayedMockReply(after: 3) }
                    .accessibilityIdentifier("blind.mock.reply.delayed")
                Button("読めない") { host.inject(mockJSON: #"{"type":"beep","name":"read_denied"}"#) }
                    .accessibilityIdentifier("blind.mock.read_denied")
                Button("TEXT へ") { host.inject(mockJSON: #"{"type":"output","mode":"text"}"#) }
                    .accessibilityIdentifier("blind.mock.output.text")
            }
            Text("\(host.debugHaptics.count)|\(host.debugHaptics.joined(separator: ","))")
                .accessibilityIdentifier("blind.debug.haptics")
            Text("\(host.debugAudioStarts)")
                .accessibilityIdentifier("blind.debug.audioStarts")
            Text("\(host.debugTonePlayers)")
                .accessibilityIdentifier("blind.debug.tones")
            Text("enabled=\(host.enabled ? 1 : 0) connects=\(host.connectCount) proto=\(host.proto ?? 0) rev=\(host.debugRevision)")
                .accessibilityIdentifier("blind.debug.host")
        }
        .buttonStyle(.bordered)
        .font(.caption2.monospaced())
    }

    /// 240 字を超える 300 字。
    static let longText = String(repeating: "あいうえおかきくけこ", count: 30)
}
