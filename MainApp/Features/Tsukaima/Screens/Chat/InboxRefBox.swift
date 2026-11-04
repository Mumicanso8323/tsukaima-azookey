import SwiftUI

/// 「Claude に伝える」欄(注文カード・お知らせなど、ref ごとの伝言)。Web 版の inboxBox と同じ:
/// 送った文はメインのセッションに打ち込まれ、届いたら ✓、届けられない間は「保留中」。
/// POST /api/inbox は署名つき(signed: true)。一覧の GET は署名不要。
/// 他の画面から `InboxRefBox(ref: "order:12", initial: o.inbox)` のように埋め込んで使う。
struct InboxRefBox: View {
    let ref: String
    var initial: [InboxMessage]? = nil

    @State private var msgs: [InboxMessage] = []
    @State private var draft = ""
    @State private var busy = false
    @State private var message: String?

    private static let stLabel: [String: String] = ["delivered": "✓", "pending": "保留中", "sending": "送信中", "failed": "⚠ 届かず"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(msgs.enumerated()), id: \.offset) { _, m in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.bubble").font(.caption2)
                    Text(m.text ?? "").font(.footnote)
                    Text(CSDate.hm(m.ts)).font(.caption2).foregroundStyle(.secondary)
                    if let s = m.status, let l = Self.stLabel[s] {
                        Text(l).font(.caption2).foregroundStyle(s == "failed" ? Color.red : Color.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Claude に伝える", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                Button("送信") { Task { await send() } }
                    .buttonStyle(.bordered)
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { if msgs.isEmpty, let initial { msgs = initial } }
        .task(id: ref) { if initial == nil { await reload() } }
    }

    private func reload() async {
        if let list = try? await CSNet.get("/api/inbox", query: ["ref": ref], as: [InboxMessage].self) {
            msgs = list
        }
    }

    private func send() async {
        let text = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !text.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let m = try await CSNet.send("POST", "/api/inbox", json: ["text": text, "ref": ref], signed: true, as: InboxMessage.self)
            msgs.append(m)
            draft = ""
            message = nil
            // 届いたかを反映(Web 版と同じく 2 秒後・12 秒後に読み直す)
            Task {
                try? await Task.sleep(for: .seconds(2)); await reload()
                try? await Task.sleep(for: .seconds(10)); await reload()
            }
        } catch {
            message = "送れませんでした: " + CSNet.message(error)
        }
    }
}
