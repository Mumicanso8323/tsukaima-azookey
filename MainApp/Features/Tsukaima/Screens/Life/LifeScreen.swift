import SwiftUI

/// 「生活」タブ: 食事・ヘルスケア・買い物・睡眠(夜の余裕)・体重・出費・分割(Web 版 tabs.life)
struct LifeScreen: View {
    var body: some View {
        NavigationStack {
            SLLifeHome()
                .navigationTitle("生活")
                .navigationDestination(for: SLLifeRoute.self) { route in
                    switch route {
                    case .shop: SLShopView()
                    case .earphones: SLEarphonesView()
                    case .orders: SLOrdersView()
                    case .checklist: SLChecklistView()
                    }
                }
        }
    }
}

enum SLLifeRoute: Hashable {
    case shop
    case earphones
    case orders
    case checklist
}

/// 生活タブの本体。ステップアップ(Face ID)が要る 3 つ(出費・分割・注文)は、断られても他の欄は出すよう別に読む
private struct SLLifeHome: View {
    @State private var meals: [SLJSON] = []
    @State private var shop: [SLJSON] = []
    @State private var earphones: SLJSON = .null
    @State private var weight: [SLJSON] = []
    @State private var nights: SLJSON = .null
    @State private var health: [SLJSON] = []
    @State private var loaded = false
    @State private var error: String?

    @State private var spend: SLJSON?
    @State private var installments: SLJSON?
    @State private var orders: SLJSON?
    @State private var lockedError: String?
    @State private var lockedAt: Date?
    @State private var lockedTried = false
    @State private var message: String?
    @State private var followUp: Task<Void, Never>?
    @State private var web: SLWebTarget?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !loaded {
                    SLLoadState(error: error) { Task { await load() } }
                } else {
                    let today0 = SLFmt.isoDay()
                    SLMealsCard(meals: meals.filter { $0["ts"].text.hasPrefix(today0) }, changed: mealsChanged)
                    SLHealthCard(rows: health, today0: today0)
                    shopping
                    SLNightsCard(data: nights)
                    SLWeightCard(all: weight) { await load() }
                    money
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await load(pulled: true) }
        .task {
            // UI テスト(--web-mock-page)は hub に届かないので、読み込み待ちを飛ばして Web 行まで出す
            if TsukaimaWebView.isMockPage { loaded = true; return }
            await load()
        }
        .fullScreenCover(item: $web) { target in SLWebCover(target: target) { web = nil } }
        .onDisappear { followUp?.cancel() }
        .slToast($message)
    }

    // 買い物: 一覧・イヤホン比較・注文・Web 版にしかないランキング類
    @ViewBuilder private var shopping: some View {
        let active = shop.filter { $0["status"].text != "bought" && $0["status"].text != "skip" }
        let picked = active.filter { $0["pick"].truthy && $0["status"].text == "want" }.count
        let items = earphones["items"].array
        let want = items.filter { $0["want"].truthy }.count
        SLHeader(title: "買い物")
        NavigationLink(value: SLLifeRoute.shop) {
            SLLinkRow(icon: "🛒", title: "買い物リスト", sub: "候補 \(active.count) 件\(picked > 0 ? " · 選んだ物 \(picked) 点" : "")")
        }
        .buttonStyle(.plain)
        NavigationLink(value: SLLifeRoute.earphones) {
            SLLinkRow(icon: "🎧", title: "イヤホン比較", sub: "\(items.count) 機種を採点\(want > 0 ? " · ♥ \(want)" : "")")
        }
        .buttonStyle(.plain)
        NavigationLink(value: SLLifeRoute.orders) {
            SLLinkRow(icon: "📦", title: "注文", sub: ordersSub)
        }
        .buttonStyle(.plain)
        NavigationLink(value: SLLifeRoute.checklist) {
            SLLinkRow(icon: "🎒", title: "帰る前のチェックリスト", sub: "外出の通知と朝のまとめに出す持ち物")
        }
        .buttonStyle(.plain)
        SLWebLinkRow(icon: "🧍", title: "3Dモデル ランキング", sub: "BOOTH の候補を比較", path: "/booth3d.html") { web = $0 }
        SLWebLinkRow(icon: "🛋️", title: "部屋の素材 ランキング", sub: "VR の部屋候補を比較", path: "/rooms.html") { web = $0 }
        SLWebLinkRow(icon: "⌨️", title: "キーボード カタログ", sub: "人間工学・手に着ける型の比較", path: "/keyboards.html") { web = $0 }
        SLWebLinkRow(icon: "🔊", title: "声の聴き比べ", sub: "候補音声を聴いて投票", path: "/voice-ab.html") { web = $0 }
        SLWebLinkRow(icon: "🎨", title: "アイコンの候補", sub: "瑞希モチーフの新アイコンを選ぶ", path: "/icons.html") { web = $0 }
    }

    private var ordersSub: String {
        guard let od = orders else { return "Face ID で確認してから表示します" }
        let p = od["pending"].array.count, r = od["recent"].array.count
        if p + r == 0 { return "最近の注文はありません" }
        return "\(p > 0 ? "確認・処理中 \(p) 件 · " : "")最近 \(r) 件"
    }

    // 出費・分割(支払いデータは Face ID の確認が要る)
    @ViewBuilder private var money: some View {
        if let spend {
            SLSpendCard(s: spend) { await loadLocked() }
        }
        if let installments {
            SLInstallmentsCard(d: installments) { await loadLocked() }
        }
        if spend == nil || installments == nil {
            SLHeader(title: "出費・分割")
            SLCard {
                SLSub(lockedError ?? "支払いの記録は Face ID で確認してから表示します。")
                Button("Face ID で表示") { Task { await loadLocked() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// タブを開き直すたびに Face ID を求めないよう、支払いデータは「初回・引っ張って更新・昇格トークンがまだ有効な間」だけ読み直す
    private func load(pulled: Bool = false) async {
        do {
            async let m = SLAPI.get("/api/meals", query: ["days": "2"])
            async let s = SLAPI.get("/api/shopping")
            async let e = SLAPI.get("/api/earphones")
            async let w = SLAPI.get("/api/weight")
            async let n = SLAPI.get("/api/nights")
            async let h = SLAPI.get("/api/health", query: ["days": "7"])
            let (mm, ss, ee, ww, nn, hh) = try await (m, s, e, w, n, h)
            meals = mm.array; shop = ss.array; earphones = ee; weight = ww.array; nights = nn; health = hh.array
            loaded = true
            error = nil
        } catch {
            if loaded { message = SLError.message(error, fallback: "読み込めませんでした") }
            else { self.error = SLError.message(error) }
        }
        let fresh = lockedAt.map { Date().timeIntervalSince($0) < 240 } ?? false
        if loaded && (pulled || !lockedTried || fresh) { await loadLocked() }
    }

    /// Face ID は 5 分キャッシュされるので、順番に読めば確認は 1 回で済む
    private func loadLocked() async {
        lockedTried = true
        do {
            spend = try await SLAPI.getStepup("/api/spend")
            orders = try await SLAPI.getStepup("/api/orders")
            installments = try? await SLAPI.getStepup("/api/installments")  // Web 版も失敗時は欄ごと出さない
            lockedError = nil
            lockedAt = Date()
        } catch {
            lockedError = SLError.message(error, fallback: "読み込めませんでした")
        }
    }

    /// 食事を記録・編集したら、推定(バックグラウンド)が終わる頃にもう一度読む
    private func mealsChanged() {
        Task { await reloadMeals() }
        followUp?.cancel()
        followUp = Task {
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { await reloadMeals() }
        }
    }

    private func reloadMeals() async {
        if let m = try? await SLAPI.get("/api/meals", query: ["days": "2"]) { meals = m.array }
    }
}

/// 開く Web ページ(fullScreenCover(item:) 用。行ではなく SLLifeHome が持つので、LazyVStack の行の再利用でカバーが消えない)
struct SLWebTarget: Identifiable {
    let title: String
    let path: String
    var id: String { path }
}

/// Web 版にしかないページ(公開ホスト経由でアプリ内の WebView に開く。Tailscale 不要)
struct SLWebLinkRow: View {
    let icon: String
    let title: String
    let sub: String
    let path: String
    let open: (SLWebTarget) -> Void

    var body: some View {
        Button { open(SLWebTarget(title: title, path: path)) } label: {
            SLLinkRow(icon: icon, title: title, sub: sub)
        }
        .buttonStyle(.plain)
    }
}

struct SLWebCover: View {
    let target: SLWebTarget
    let close: () -> Void
    @State private var cookieState = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.title).font(.headline).lineLimit(1)
                Spacer()
                Button("閉じる", action: close)
                    .accessibilityIdentifier("web.close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if TsukaimaWebView.isMockPage {
                Text(cookieState.isEmpty ? "pending" : cookieState)
                    .font(.caption2)
                    .accessibilityIdentifier("web.cookie.state")
            }
            TsukaimaWebView(url: TsukaimaEndpoint.publicURL(target.path)) { cookieState = $0 }
        }
        .onDisappear { Task { @MainActor in TsukaimaWebView.removeDeviceCookie() } }
    }
}
