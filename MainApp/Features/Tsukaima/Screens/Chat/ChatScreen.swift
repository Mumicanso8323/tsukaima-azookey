import SwiftUI

/// 「使い魔」タブ(= 本人のメインの Claude Code セッションの窓)。Web 版 app.js の chat と同じ動き:
/// 送った文は hub の tmux の claude-bunri に本人が打ったのと同じ形で入る。表示はそのセッションの記録を
/// 3.5 秒おきに読む。届けられない間は hub で保留し、届き次第送る。
/// /api/main/* は端末に縛った毎回の署名が要る(signed: true)。
struct ChatScreen: View {
    @StateObject private var model = ChatModel()
    @ObservedObject private var prefill = ChatPrefill.shared
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            SurveyLinkCard(count: model.surveyOpen, answered: model.surveyAnswered)
                            if model.turns.isEmpty && model.loaded {
                                emptyState
                            }
                            ForEach(Array(model.turns.enumerated()), id: \.offset) { _, t in
                                ChatTurnRow(turn: t)
                            }
                            ForEach(model.visibleQueue) { q in
                                ChatQueueRow(item: q)
                            }
                            if model.showTyping {
                                ChatTypingRow()
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.scrollToken) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                composer
            }
            .navigationTitle("使い魔")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { dest in
                if dest == "survey" { SurveyScreen(onChange: { Task { await model.loadSurvey() } }) }
            }
        }
        .tsukaimaTextSize()
        .task {
            // 画面が見えている間だけ 3.5 秒おきに読む(タブを離れると task ごと止まる)
            await model.loadSurvey()
            await model.poll(force: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(3500))
                if Task.isCancelled { break }
                if model.active { await model.poll(force: false) }
            }
        }
        .onChange(of: phase) { _, p in
            model.active = p == .active
            if p == .active { Task { await model.poll(force: false) } }
        }
        .onChange(of: prefill.text, initial: true) { _, t in
            guard let t else { return }
            draft = t
            prefill.text = nil
            focused = true
        }
        .alert(model.toast ?? "", isPresented: Binding(get: { model.toast != nil }, set: { if !$0 { model.toast = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // ---- 接続状態(上端の帯) ----
    @ViewBuilder private var statusBar: some View {
        if let line = model.statusLine {
            HStack(spacing: 6) {
                if model.statusOK {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                }
                Text(line).font(.caption).lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(model.statusOK ? Color.secondary : Color.orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.purple)
            Text("メインのセッション").font(.headline)
            Text("ここに書いた文は、hub で動いている Claude Code(claude-bunri)にそのまま届きます。")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // ---- 入力欄(空のときだけ定型文のチップを出す) ----
    private var composer: some View {
        VStack(spacing: 6) {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ChatChip.all) { chip in
                            Button(chip.label) {
                                if chip.sendNow {
                                    Task { await model.send(chip.text) }
                                } else {
                                    draft = chip.text
                                    focused = true
                                }
                            }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .disabled(model.sending)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("メインのセッションに送る", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    let text = draft
                    Task {
                        if await model.send(text) { draft = "" }
                    }
                } label: {
                    if model.sending {
                        ProgressView().frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                    }
                }
                .disabled(model.sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("送信")
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// ---------- 状態と通信 ----------
@MainActor
final class ChatModel: ObservableObject {
    @Published var turns: [ChatTurn] = []
    @Published var queue: [ChatQueueItem] = []
    @Published var status: ChatStatus?
    @Published var error: String?
    @Published var loaded = false
    @Published var sending = false
    @Published var toast: String?
    @Published var surveyOpen = 0
    @Published var surveyAnswered = 0
    /// 変わるたびに一番下まで送る
    @Published var scrollToken = 0

    /// アプリが前面にある間だけ読みに行く
    var active = true
    private var sig = ""

    func poll(force: Bool) async {
        let v: ChatView
        do {
            v = try await CSNet.send("GET", "/api/main/view?limit=60", signed: true, as: ChatView.self)
        } catch {
            self.error = CSNet.message(error, fallback: "hub に接続できません")
            return
        }
        error = nil
        let last = v.turns.last
        let newSig = "\(v.turns.count)|\(last?.r ?? "")|\(last?.t?.count ?? 0)|\(last?.n ?? 0)|"
            + v.queue.map { $0.status ?? "" }.joined(separator: ",")
        let changed = newSig != sig
        sig = newSig
        status = v.status
        queue = v.queue
        loaded = true
        if changed || force {
            turns = v.turns
            scrollToken += 1
        }
    }

    func loadSurvey() async {
        guard let d = try? await CSNet.get("/api/survey", as: SurveyList.self) else { return }
        surveyOpen = d.open.count
        surveyAnswered = d.answered.count
    }

    /// 送信(hub のキューへ。届けるのは hub)。成功したら true
    @discardableResult
    func send(_ raw: String) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return false }
        sending = true
        defer { sending = false }
        do {
            let q = try await CSNet.send("POST", "/api/main/send", json: ["text": text], signed: true, as: ChatQueueItem.self)
            queue.append(q)
            scrollToken += 1
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                await self.poll(force: false)
            }
            return true
        } catch {
            toast = "送れませんでした: " + CSNet.message(error)
            return false
        }
    }

    // ---- 表示用 ----
    var statusOK: Bool { error == nil && status?.connected == true }

    var statusLine: String? {
        if let error { return error }
        guard let s = status else { return nil }
        var pend = ""
        if let n = s.pending, n > 0 {
            pend = " · 保留 \(n) 件"
            if let r = s.reason, !r.isEmpty { pend += "(\(r))" }
        }
        if s.connected == true { return "メインのセッションに接続中(\(s.session ?? ""))\(pend)" }
        return "セッションが見つかりません — 送信は保留して届き次第送ります\(pend)"
    }

    /// まだ記録に出ていない送信(保留中・順番待ち・失敗)。Web 版と同じ間引き方
    var visibleQueue: [ChatQueueItem] {
        let norm: (String?) -> String = { ($0 ?? "").filter { !$0.isWhitespace } }
        let seen = Set(turns.filter { $0.r == "me" }.suffix(30).map { norm($0.t) })
        let now = Date()
        return queue.filter { q in
            let age = now.timeIntervalSince(CSDate.parse(q.ts) ?? now)
            if q.status == "delivered" {
                let dAge = now.timeIntervalSince(CSDate.parse(q.deliveredAt ?? q.ts) ?? now)
                if seen.contains(norm(q.text)) || dAge > 30 * 60 { return false }
            }
            if q.status == "failed", age > 6 * 3600 { return false }
            return true
        }
    }

    /// 最後の記録が返答以外で 10 分以内なら「考え中」を出す
    var showTyping: Bool {
        guard let last = turns.last, last.r != "ai", let d = CSDate.parse(last.ts) else { return false }
        return Date().timeIntervalSince(d) < 10 * 60
    }
}

// ---------- 定型文 ----------
struct ChatChip: Identifiable {
    let label: String
    let text: String
    /// true: 押したらすぐ送る / false: 入力欄に入れて続きを書く
    let sendNow: Bool
    var id: String { label }

    static let all: [ChatChip] = [
        ChatChip(label: "今日の予定まとめて", text: "今日の授業・予定・締切を短くまとめて。気をつけることがあれば一言。", sendNow: true),
        ChatChip(label: "課題を手伝って", text: "課題を手伝って。対象の課題: ", sendNow: false),
        ChatChip(label: "授業ノートを要約", text: "直近の授業ノートを要点だけ要約して。", sendNow: true),
        ChatChip(label: "締切を確認", text: "1 週間以内の締切を近い順に一覧にして。", sendNow: true),
        ChatChip(label: "買い物の相談", text: "買い物の相談: ", sendNow: false),
        ChatChip(label: "使い魔を直して", text: "使い魔アプリの不具合: ", sendNow: false),
    ]
}

// ---------- 1 行ずつの表示 ----------
private let chatToolJa: [String: String] = [
    "Read": "読む", "Grep": "検索", "Glob": "ファイルを探す", "Bash": "コマンド", "Edit": "編集", "MultiEdit": "編集",
    "Write": "書き込み", "WebFetch": "Web を読む", "WebSearch": "Web 検索", "Task": "手分け", "Agent": "手分け",
    "TodoWrite": "やること整理", "NotebookEdit": "編集",
]

private func chatToolName(_ n: String?) -> String {
    let n = n ?? ""
    if let ja = chatToolJa[n] { return ja }
    if let r = n.range(of: #"^mcp__[^_]+__"#, options: .regularExpression) { return String(n[r.upperBound...]) }
    return n
}

struct ChatTurnRow: View {
    let turn: ChatTurn

    var body: some View {
        switch turn.r {
        case "tool":
            let names = (turn.names ?? []).map(chatToolName)
            let uniq = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            Label("\(turn.n ?? 1) 回 · \(uniq.joined(separator: "・"))", systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case "me":
            ChatBubble(mine: true) { Text(turn.t ?? "") }
        default:
            ChatBubble(mine: false) { ChatRichText(source: turn.t ?? "") }
        }
    }
}

struct ChatQueueRow: View {
    let item: ChatQueueItem

    private static let label: [String: String] = [
        "pending": "保留中", "sending": "送信中…", "delivered": "✓ 届きました(順番待ち)", "failed": "届けられませんでした",
    ]

    var body: some View {
        let st = item.status ?? ""
        VStack(alignment: .trailing, spacing: 2) {
            ChatBubble(mine: true, faded: st != "delivered", failed: st == "failed") { Text(item.text ?? "") }
            let reason = (st != "delivered" && !(item.reason ?? "").isEmpty) ? " · \(item.reason ?? "")" : ""
            Text((Self.label[st] ?? st) + reason)
                .font(.caption2)
                .foregroundStyle(st == "failed" ? Color.red : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ChatBubble<Content: View>: View {
    let mine: Bool
    var faded = false
    var failed = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            content()
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? Color.accentColor.opacity(faded ? 0.35 : 0.8) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    if failed { RoundedRectangle(cornerRadius: 16).stroke(Color.red, lineWidth: 1) }
                }
                .foregroundStyle(mine ? Color.white : Color.primary)
            if !mine { Spacer(minLength: 24) }
        }
    }
}

struct ChatTypingRow: View {
    @State private var on = false
    var body: some View {
        ChatBubble(mine: false) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 6, height: 6)
                        .opacity(on ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
                }
            }
            .foregroundStyle(.secondary)
            .onAppear { on = true }
        }
        .accessibilityLabel("返答を書いています")
    }
}

/// 使い魔タブの上に出す「ひまな時アンケート(N問)」
struct SurveyLinkCard: View {
    let count: Int
    let answered: Int

    var body: some View {
        NavigationLink(value: "survey") {
            HStack {
                Image(systemName: "envelope.open")
                VStack(alignment: .leading, spacing: 2) {
                    Text("ひまな時アンケート(\(count)問)").font(.subheadline)
                    let sub = count > 0 ? "暇なときにでも" : answered > 0 ? "答えたものを見る" : ""
                    if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
