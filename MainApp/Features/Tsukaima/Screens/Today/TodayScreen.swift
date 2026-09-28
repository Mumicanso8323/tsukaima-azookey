import SwiftUI

/// 今日タブから開く画面
enum TodayRoute: Hashable {
    case notices
    case mails
    case orders
    case notice(String)
    case mail(String)
    case lecture(Int)
}

/// 「今日」タブ(web 版 tabs.today のネイティブ版)。
/// 録音 → アンケート/聴き比べ → 注文の確認 → 起床アラーム → 授業 → 予定 → TRPG → 締切 → 未読の重要なもの
struct TodayScreen: View {
    @State private var path: [TodayRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            TodayHomeView()
                .navigationTitle("今日")
                .navigationDestination(for: TodayRoute.self) { route in
                    switch route {
                    case .notices: TodayNoticesView()
                    case .mails: TodayMailsView()
                    case .orders: TodayOrdersView()
                    case .notice(let id): TodayNoticeDetailView(id: id)
                    case .mail(let id): TodayMailDetailView(id: id)
                    case .lecture(let id): TodayLectureDetailView(id: id)
                    }
                }
        }
    }
}

struct TodayHomeView: View {
    @State private var data: TodayJSON?
    @State private var important: [(item: TodayJSON, isMail: Bool)] = []
    @State private var surveyOpen = 0
    @State private var error: String?
    @State private var toast: String?
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var phase

    /// 声の聴き比べは web のページ(api.yusukedoi.com)で開く
    static let voiceAbURL = URL(string: "https://api.yusukedoi.com/voice-ab.html")!

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let data {
                    content(data)
                } else if let error {
                    TodayLoadError(message: error) { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await load() }
        .task { if data == nil { await load() } }
        .onAppear { if data != nil { Task { await load() } } }  // 詳細から戻ったら既読などを反映
        .onChange(of: phase) { _, p in if p == .active, data != nil { Task { await load() } } }
        .todayToast($toast)
    }

    private func load() async {
        do {
            async let d = TodayAPI.get("/api/today")
            async let n = TodayAPI.get("/api/notices", query: ["min_importance": "2", "limit": "8"])
            async let m = TodayAPI.get("/api/mails", query: ["min_importance": "2", "limit": "8"])
            async let sv = try? TodayAPI.get("/api/survey")
            let (dv, nv, mv) = try await (d, n, m)
            let svv = await sv
            data = dv
            let notices = nv.arr.map { (item: $0, isMail: false) }
            let mails = mv.arr.map { (item: $0, isMail: true) }
            important = (notices + mails).filter { !$0.item["read"].truthy }
            surveyOpen = svv?["open"].arr.count ?? 0
            error = nil
        } catch {
            if TodayAPI.isCancelled(error) { return }
            if data == nil {
                self.error = TodayAPI.message(error)
            } else {
                toast = "更新できませんでした(\(TodayAPI.message(error)))"
            }
        }
    }

    @ViewBuilder
    private func content(_ d: TodayJSON) -> some View {
        recordButton(d)

        // ひまな時アンケート(未回答があるときだけ)
        if surveyOpen > 0 {
            TodayLinkRow(icon: "📮", label: "ひまな時アンケート 未回答 \(surveyOpen) 件", sub: "暇なときにでも(使い魔タブで回答)", chevron: false)
        }
        if d["voice_ab"]["pending"].truthy {
            Link(destination: Self.voiceAbURL) {
                TodayLinkRow(icon: "🔊", label: "声の聴き比べ(未回答)", sub: "候補音声を聴いて投票")
            }
            .buttonStyle(.plain)
        }

        ordersBlock(d)

        // 起床アラーム(授業がある日だけ)
        if d["alarm"]["has_class"].truthy {
            HStack(spacing: 10) {
                Text("⏰").font(.title3)
                Text(d["alarm"]["text"].s)
                Spacer(minLength: 0)
            }
            .todayCard()
        }

        TodayClassesSection(data: d, reload: { await load() }, toast: { toast = $0 })
        scheduleBlock(d)
        trpgBlock(d)
        deadlinesBlock(d)
        importantBlock()
    }

    // 録音(アプリの録音画面を開いて、授業中ならその授業名で始める)
    private func recordButton(_ d: TodayJSON) -> some View {
        let cur = d["current"]
        let title = cur.truthy ? "\(cur["title"].s) を録音" : "録音して文字起こし"
        return Button {
            var c = URLComponents()
            c.scheme = "tsukaima-rec"
            c.host = "record"
            if cur.truthy { c.queryItems = [URLQueryItem(name: "course", value: cur["title"].s)] }
            if let url = c.url { router.open(url) }  // 使い魔タブの録音画面を開いて録音開始
        } label: {
            HStack(spacing: 10) {
                Circle().fill(.white).frame(width: 12, height: 12)
                Text(title).font(.headline).lineLimit(2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    // 注文: いちばん大事な 1 件だけカードで、残りは 1 行にまとめて「注文」画面へ
    @ViewBuilder
    private func ordersBlock(_ d: TodayJSON) -> some View {
        let all = d["orders"].arr + d["orders_recent"].arr
        let top = TodayOrderLogic.pickTop(all)
        if let top {
            TodayOrderCard(order: top, reload: { await load() }, toast: { toast = $0 })
        }
        let others = all.filter { $0 != top }
        if !others.isEmpty {
            NavigationLink(value: TodayRoute.orders) {
                TodayLinkRow(icon: "🛒", label: "注文 \(others.count)件", sub: TodayOrderLogic.rowSub(others))
            }
            .buttonStyle(.plain)
        }
    }

    // 予定(休講・補講・教室変更 / iCloud の今日の予定)
    @ViewBuilder
    private func scheduleBlock(_ d: TodayJSON) -> some View {
        let changes: [TodayScheduleRow] = d["changes"].arr.map {
            TodayScheduleRow(time: TodayFmt.md($0["start"].s), title: $0["title"].s, sub: $0["note"].s, tag: "変更", role: "", prep: "")
        }
        let personal: [TodayScheduleRow] = d["personal"].arr.map { p in
            TodayScheduleRow(time: p["note"].s.hasPrefix("終日") ? "終日" : TodayFmt.hm(p["start"].s),
                             title: p["title"].s,
                             sub: p["location"].truthy ? "📍 " + p["location"].s : "",
                             tag: "", role: p["trpg_role"].s, prep: p["kp_prep"]["text"].s)
        }
        let rows = changes + personal
        if !rows.isEmpty {
            TodaySectionHeader(title: "予定")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, x in
                    if i > 0 { Divider() }
                    x
                }
            }
            .todayCard()
        }
    }

    // TRPG(今日から先。KP は準備目安つき)
    @ViewBuilder
    private func trpgBlock(_ d: TodayJSON) -> some View {
        let list = d["trpg_upcoming"].arr
        if !list.isEmpty {
            TodaySectionHeader(title: "TRPG")
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, t in
                    if i > 0 { Divider() }
                    TodayScheduleRow(time: TodayFmt.md(t["start"].s), title: t["title"].s, sub: "", tag: "",
                                     role: t["trpg_role"].s, prep: t["kp_prep"]["text"].s)
                }
            }
            .todayCard()
        }
    }

    // 締切(2 週間以内。それより先は折りたたみ)
    @ViewBuilder
    private func deadlinesBlock(_ d: TodayJSON) -> some View {
        let all = d["deadlines"].arr
        if !all.isEmpty {
            let soon = all.filter { TodayFmt.daysTo($0["start"].s) <= 14 }
            let later = all.filter { TodayFmt.daysTo($0["start"].s) > 14 }
            TodaySectionHeader(title: "締切")
            VStack(alignment: .leading, spacing: 0) {
                if soon.isEmpty {
                    Text("2 週間以内の締切はありません").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(Array(soon.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Divider() }
                    TodayDeadlineRow(c: c)
                }
                if !later.isEmpty {
                    DisclosureGroup {
                        ForEach(Array(later.enumerated()), id: \.offset) { i, c in
                            if i > 0 { Divider() }
                            TodayDeadlineRow(c: c)
                        }
                    } label: {
                        Text("その先 \(later.count) 件").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
            .todayCard()
        }
    }

    // 未読の重要なもの + 一覧へ
    @ViewBuilder
    private func importantBlock() -> some View {
        TodaySectionHeader(title: "未読の重要なもの")
        if important.isEmpty {
            TodayEmpty(text: "重要な未読はありません")
        }
        ForEach(Array(important.enumerated()), id: \.offset) { _, x in
            let card = TodayItemCard(item: x.item, isMail: x.isMail)
            NavigationLink(value: card.route) { card }.buttonStyle(.plain)
        }
        HStack(spacing: 10) {
            NavigationLink(value: TodayRoute.notices) {
                TodayLinkRow(icon: "📢", label: "お知らせ", sub: "すべて見る")
            }
            .buttonStyle(.plain)
            NavigationLink(value: TodayRoute.mails) {
                TodayLinkRow(icon: "📩", label: "メール", sub: "すべて見る")
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }
}

/// 予定・TRPG の 1 行(時刻 | 題名 + 場所 + KP 準備目安)。TRPG は左に色の帯
struct TodayScheduleRow: View {
    let time: String
    let title: String
    let sub: String
    let tag: String
    let role: String
    let prep: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if !role.isEmpty {
                RoundedRectangle(cornerRadius: 2).fill(TodayColors.trpg(role)).frame(width: 3)
            }
            Text(time)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if !tag.isEmpty { TodayBadge(text: tag, color: .orange) }
                    Text(title).font(.body.weight(.semibold))
                    if !role.isEmpty { TodayTrpgChip(role: role) }
                }
                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
                if !prep.isEmpty { Text(prep).font(.caption).foregroundStyle(TodayColors.trpg(role)) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

/// 締切の 1 行(「今日」「明日」「あと N 日」+ 日付・時刻・リンク/メモ)
struct TodayDeadlineRow: View {
    let c: TodayJSON

    var body: some View {
        let start = c["start"].s
        let n = TodayFmt.daysTo(start)
        let note = c["note"].s
        let url = note.range(of: "^https?:", options: .regularExpression) != nil ? URL(string: note) : nil
        let time = start.count > 10 && TodayFmt.hm(start) != "00:00" ? " " + TodayFmt.hm(start) : ""
        HStack(alignment: .top, spacing: 10) {
            Text(TodayFmt.dueLabel(start))
                .font(.caption.weight(.bold))
                .foregroundStyle(n <= 1 ? Color.white : n <= 3 ? Color.orange : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(n <= 1 ? TodayColors.hot : n <= 3 ? TodayColors.warm.opacity(0.16) : Color.gray.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 6))
                .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(c["title"].s).font(.body.weight(.semibold))
                HStack(spacing: 0) {
                    Text(TodayFmt.md(start) + time)
                    if let url {
                        Text(" · ")
                        Link("開く", destination: url)
                    } else if !note.isEmpty {
                        Text(" · " + note)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}
