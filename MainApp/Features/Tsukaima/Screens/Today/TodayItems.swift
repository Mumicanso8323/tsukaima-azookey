import SwiftUI

/// お知らせ・メールの 1 件(web 版 itemCard)。k: "n" = お知らせ / "m" = メール
struct TodayItemCard: View {
    let item: TodayJSON
    let isMail: Bool

    var body: some View {
        let unread = !item["read"].truthy
        let title = isMail ? item["subject"].s : item["title"].s
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(isMail ? "📩" : "📢") \(title)")
                    .font(.body.weight(unread ? .bold : .regular))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                TodayImportanceBadge(importance: item["importance"].int)
            }
            Text("\(sub) · \(TodayFmt.md(item["received"].truthy ? item["received"].s : item["first_seen"].s))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if item["summary"].truthy {
                Text(item["summary"].s)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
        }
        .todayCard()
        .overlay(alignment: .leading) {
            if unread {
                RoundedRectangle(cornerRadius: 2).fill(TodayColors.accent).frame(width: 3).padding(.vertical, 10)
            }
        }
        .contentShape(Rectangle())
    }

    private var sub: String {
        if isMail {
            let account = item["account"].s
            let acc = account.isEmpty ? "" : account.hasSuffix("bunri-u.ac.jp") ? "大学"
                : String((account.split(separator: "@").first.map(String.init) ?? account).prefix(8))
            let sender = item["sender"].s.replacingOccurrences(of: "<.*>", with: "", options: .regularExpression)
            return (acc.isEmpty ? "" : "[\(acc)] ") + sender
        }
        return item["category"].s
    }

    var route: TodayRoute { isMail ? .mail(item["id"].s) : .notice(item["id"].s) }
}

/// 重要度フィルタ(重要のみ / 参考も / すべて)
struct TodayImportanceFilter: View {
    @Binding var value: Int

    var body: some View {
        Picker("", selection: $value) {
            Text("重要のみ").tag(2)
            Text("参考も").tag(1)
            Text("すべて").tag(0)
        }
        .pickerStyle(.segmented)
    }
}

/// 「お知らせ」一覧(今日の「すべて見る」から)
struct TodayNoticesView: View {
    @AppStorage("tsukaima.today.f-notices") private var filter = 2
    @State private var list: [TodayJSON]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                TodayImportanceFilter(value: $filter)
                if let error {
                    TodayLoadError(message: error) { Task { await load() } }
                } else if let list {
                    if list.isEmpty { TodayEmpty(text: "なし") }
                    ForEach(Array(list.enumerated()), id: \.offset) { _, n in
                        let card = TodayItemCard(item: n, isMail: false)
                        NavigationLink(value: card.route) { card }.buttonStyle(.plain)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle("お知らせ")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: filter) { await load() }
        .onAppear { if list != nil { Task { await load() } } }  // 詳細から戻ったら既読を反映
    }

    private func load() async {
        do {
            let v = try await TodayAPI.get("/api/notices", query: ["min_importance": String(filter)])
            list = v.arr
            error = nil
        } catch {
            if TodayAPI.isCancelled(error) { return }
            if list == nil { self.error = TodayAPI.message(error) }
        }
    }
}

/// 「メール」一覧(今日の「すべて見る」から)
struct TodayMailsView: View {
    @AppStorage("tsukaima.today.f-mails") private var filter = 1
    @State private var list: [TodayJSON]?
    @State private var connected = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !connected {
                    Text("大学の Google アカウントと連携するとメールが表示されます。設定タブから連携できます。")
                        .font(.subheadline)
                        .todayCard()
                }
                TodayImportanceFilter(value: $filter)
                if let error {
                    TodayLoadError(message: error) { Task { await load() } }
                } else if let list {
                    if list.isEmpty { TodayEmpty(text: "なし") }
                    ForEach(Array(list.enumerated()), id: \.offset) { _, m in
                        let card = TodayItemCard(item: m, isMail: true)
                        NavigationLink(value: card.route) { card }.buttonStyle(.plain)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle("メール")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: filter) { await load() }
        .onAppear { if list != nil { Task { await load() } } }
    }

    private func load() async {
        do {
            async let l = TodayAPI.get("/api/mails", query: ["min_importance": String(filter)])
            async let g = TodayAPI.get("/api/today")
            let (lv, gv) = try await (l, g)
            list = lv.arr
            connected = gv["google"]["connected"].truthy
            error = nil
        } catch {
            if TodayAPI.isCancelled(error) { return }
            if list == nil { self.error = TodayAPI.message(error) }
        }
    }
}

/// 「使い魔に聞く」: 本文は渡さず、どの画面の物かの参照だけを入れてメインのセッションに送る
/// (web 版は使い魔タブの入力欄に「(使い魔の画面: notice:…) 」を入れて開く。ここではその場で送る)
struct TodayAskSheet: View {
    let ref: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var errorText: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TsukaimaTextEditor(text: $text)
                    .frame(minHeight: 140)
                    .padding(6)
                    .background(TodayColors.card, in: RoundedRectangle(cornerRadius: 10))
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.orange)
                }
                if sent {
                    Text("送りました。返事は使い魔タブで見られます。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("本文は渡さず、どの画面かだけを伝えます(使い魔が自分で調べます)。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle("使い魔に聞く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "閉じる" : "やめる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("送る") { Task { await send() } }
                        .disabled(sending || sent || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { if text.isEmpty { text = "(使い魔の画面: \(ref)) " } }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            _ = try await TodayAPI.send("POST", "/api/main/send",
                                        body: ["text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines))], signed: true)
            errorText = nil
            sent = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch {
            if TodayAPI.isCancelled(error) { return }
            errorText = TodayAPI.status(error) == 429 ? "少し間を空けて送ってください" : "送れませんでした(\(TodayAPI.message(error)))"
        }
    }
}

/// お知らせの詳細(開くと既読になる)
struct TodayNoticeDetailView: View {
    let id: String
    @State private var n: TodayJSON?
    @State private var error: String?
    @State private var asking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error {
                    TodayLoadError(message: error) { Task { await load() } }
                } else if let n {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Text(n["title"].s).font(.headline)
                            Spacer(minLength: 4)
                            TodayImportanceBadge(importance: n["importance"].int)
                        }
                        Text("\(n["category"].s) · \(n["posted"].s)").font(.caption).foregroundStyle(.secondary)
                        if n["summary"].truthy {
                            (Text("要約: ").bold() + Text(n["summary"].s)).font(.subheadline)
                        }
                    }
                    .todayCard()
                    HStack(spacing: 10) {
                        if let url = URL(string: n["url"].s), n["url"].truthy {
                            Link(destination: url) { Text("ポータルで開く").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered)
                        }
                        Button { asking = true } label: { Text("使い魔に聞く").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                    }
                    Text(n["body"].s)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .todayCard()
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle("お知らせ")
        .navigationBarTitleDisplayMode(.inline)
        .task { if n == nil { await load() } }
        .sheet(isPresented: $asking) { TodayAskSheet(ref: "notice:\(id)") }
    }

    private func load() async {
        do {
            n = try await TodayAPI.get("/api/notices/\(TodayAPI.seg(id))")
            error = nil
        } catch {
            if !TodayAPI.isCancelled(error) { self.error = TodayAPI.message(error) }
        }
    }
}

/// メールの詳細(返信が要るものは下書きを Gmail に保存できる。送信はしない)
struct TodayMailDetailView: View {
    let id: String
    @State private var m: TodayJSON?
    @State private var error: String?
    @State private var asking = false
    @State private var draft = ""
    @State private var saving = false
    @State private var saved = false
    @State private var saveError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error {
                    TodayLoadError(message: error) { Task { await load() } }
                } else if let m {
                    content(m)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle("メール")
        .navigationBarTitleDisplayMode(.inline)
        .task { if m == nil { await load() } }
        .sheet(isPresented: $asking) { TodayAskSheet(ref: "mail:\(id)") }
    }

    @ViewBuilder
    private func content(_ m: TodayJSON) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(m["subject"].s).font(.headline)
                Spacer(minLength: 4)
                TodayImportanceBadge(importance: m["importance"].int)
            }
            Text("\(m["sender"].s) · \(TodayFmt.md(m["received"].s)) \(TodayFmt.hm(m["received"].s))")
                .font(.caption).foregroundStyle(.secondary)
            if m["summary"].truthy {
                (Text("要約: ").bold() + Text(m["summary"].s)).font(.subheadline)
            }
        }
        .todayCard()
        Button { asking = true } label: { Text("使い魔に聞く").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
        if m["needs_reply"].truthy {
            TodaySectionHeader(title: "返信の下書き")
            TsukaimaTextEditor(text: $draft)
                .frame(minHeight: 160)
                .padding(6)
                .background(TodayColors.card, in: RoundedRectangle(cornerRadius: 10))
            Button {
                Task { await saveDraft() }
            } label: {
                Text(saved ? "保存しました ✓" : m["gmail_draft_id"].truthy ? "Gmail の下書きを更新" : "Gmail の下書きに保存")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(saving || saved)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.orange) }
            Text("送信はしません。Gmail アプリで確認して送ってください。").font(.caption).foregroundStyle(.secondary)
        }
        TodaySectionHeader(title: "本文")
        Text(m["body"].s)
            .font(.subheadline)
            .textSelection(.enabled)
            .todayCard()
    }

    private func load() async {
        do {
            let v = try await TodayAPI.get("/api/mails/\(TodayAPI.seg(id))")
            m = v
            draft = v["reply_draft"].s
            error = nil
        } catch {
            if !TodayAPI.isCancelled(error) { self.error = TodayAPI.message(error) }
        }
    }

    private func saveDraft() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await TodayAPI.send("POST", "/api/mails/\(TodayAPI.seg(id))/draft", body: ["text": .string(draft)])
            saved = true
            saveError = nil
        } catch {
            if !TodayAPI.isCancelled(error) { saveError = "保存できませんでした(\(TodayAPI.message(error)))" }
        }
    }
}

/// 授業ノートの詳細(要約・配布資料・文字起こし)。勉強タブからも使える
struct TodayLectureDetailView: View {
    let id: Int
    @State private var l: TodayJSON?
    @State private var error: String?
    @State private var asking = false

    static let statusLabel = ["recording": "録音中", "summarizing": "要約中", "error": "エラー"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error {
                    TodayLoadError(message: error) { Task { await load() } }
                } else if let l {
                    content(l)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle(l?["course"].s ?? "授業ノート")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if l == nil { await load() } }
        .sheet(isPresented: $asking) { TodayAskSheet(ref: "lecture:\(id)") }
    }

    @ViewBuilder
    private func content(_ l: TodayJSON) -> some View {
        let st = Self.statusLabel[l["status"].s].map { " · " + $0 } ?? ""
        Text("\(TodayFmt.md(l["recorded_at"].s)) \(TodayFmt.hm(l["recorded_at"].s))\(st)")
            .font(.caption).foregroundStyle(.secondary)
        if l["summary"].truthy {
            Text(TodayRich.attributed(l["summary"].s))
                .font(.subheadline)
                .textSelection(.enabled)
                .todayCard()
        }
        Button { asking = true } label: { Text("使い魔に聞く").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
        let handouts = l["handouts"].arr
        if !handouts.isEmpty {
            TodaySectionHeader(title: "配布資料")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(handouts.enumerated()), id: \.offset) { i, h in
                    if i > 0 { Divider() }
                    HStack(spacing: 10) {
                        Text("📄")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h["name"].s).font(.subheadline.weight(.semibold))
                            Text("\(TodayFmt.md(h["ts"].s)) \(TodayFmt.hm(h["ts"].s))\(h["note"].truthy ? " · " + h["note"].s : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                }
            }
            .todayCard()
        }
        TodaySectionHeader(title: "文字起こし\(l["cleaned"].truthy ? "(補正済み)" : "")")
        let text = l["cleaned"].truthy ? l["cleaned"].s : l["transcript"].s
        Text(text.isEmpty ? "(まだありません)" : text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .todayCard()
    }

    private func load() async {
        do {
            l = try await TodayAPI.get("/api/lectures/\(id)")
            error = nil
        } catch {
            if !TodayAPI.isCancelled(error) && l == nil { self.error = TodayAPI.message(error) }
        }
    }
}
