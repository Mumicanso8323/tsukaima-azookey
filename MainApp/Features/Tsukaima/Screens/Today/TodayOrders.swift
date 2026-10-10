import SwiftUI

/// 注文まわり(web 版 orderCard / deliveryBox / inboxBox / pickTopOrder / orderArrival / ordersRow)。
enum TodayOrderLogic {
    static let statusLabel = ["pending": "確認待ち", "approved": "確定待ち", "running": "注文中…", "done": "注文済み", "failed": "失敗"]
    static let rank = ["pending": 0, "running": 1, "approved": 2, "failed": 3]

    /// 今日の画面に出す 1 件: 確認待ち > 処理中 > 確定待ち > 失敗。どれも無ければ nil
    static func pickTop(_ list: [TodayJSON]) -> TodayJSON? {
        list.filter { rank[$0["status"].s] != nil }
            .sorted { a, b in
                let ra = rank[a["status"].s] ?? 9, rb = rank[b["status"].s] ?? 9
                if ra != rb { return ra < rb }
                return (a["id"].num ?? 0) > (b["id"].num ?? 0)
            }
            .first
    }

    /// 選んだお届け方法
    static func selectedOptions(_ o: TodayJSON) -> [TodayJSON] {
        let dl = o["delivery"]
        let sel = Set(dl["selected"].arr.map(\.s))
        return dl["options"].arr.filter { sel.contains($0["key"].s) }
    }

    /// 結果文の「9/27 お届け」(曜日つきのこともある)
    static func arriveText(_ o: TodayJSON) -> String? {
        let res = o["result"].s
        guard let r = res.range(of: "\\d{1,2}/\\d{1,2}(\\([月火水木金土日]\\))? お届け", options: .regularExpression) else { return nil }
        return String(res[r]).replacingOccurrences(of: " お届け", with: "")
    }

    /// お届け日 → "明日 9/27(日)"
    static func arrival(_ o: TodayJSON) -> String {
        var iso: String?
        if let t = arriveText(o) {
            let nums = t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 2 {
                let now = Calendar.current.dateComponents([.year, .month], from: Date())
                let y = (now.year ?? 2026) + (nums[0] < (now.month ?? 1) - 6 ? 1 : 0)
                iso = String(format: "%04d-%02d-%02d", y, nums[0], nums[1])
            }
        } else {
            iso = selectedOptions(o).map { $0["date"].s }.filter { !$0.isEmpty }.sorted().last
        }
        guard let iso else { return "" }
        let n = TodayFmt.daysTo(iso)
        return (n == 0 ? "今日 " : n == 1 ? "明日 " : "") + TodayFmt.md(iso)
    }

    static func short(_ o: TodayJSON) -> String {
        var s = o["summary"].s
        if s.isEmpty { s = itemName(o["items"].arr.first ?? .null) }
        if s.isEmpty { s = o["site"].s }
        let head = s.split(whereSeparator: { $0 == "(" || $0 == "（" }).first.map(String.init) ?? s
        return String(head.trimmingCharacters(in: .whitespaces).prefix(16))
    }

    static func itemName(_ i: TodayJSON) -> String {
        if case .string(let s) = i { return s }
        return i["name"].s
    }

    static func rowSub(_ list: [TodayJSON]) -> String {
        guard let f = list.first else { return "" }
        let when = arrival(f)
        return (when.isEmpty ? "" : when + " ") + short(f) + (list.count > 1 ? " ほか" : "")
    }
}

/// 注文カード。確認待ちなら「注文する」「やめる」、処理中なら 3D セキュアのコード欄、下に「Claude に伝える」。
/// Face ID 前の /api/today では中身(品目・金額)が伏せられるので、そのときは注文画面へ誘導する。
struct TodayOrderCard: View {
    let order: TodayJSON
    let reload: @MainActor () async -> Void
    let toast: @MainActor (String) -> Void

    @State private var askConfirm = false
    @State private var askPin = false
    @State private var pin = ""
    @State private var busy = false
    @State private var otp = ""
    @State private var otpSent = false
    @State private var errorText: String? { didSet { showError = errorText != nil } }
    @State private var showError = false

    private var status: String { order["status"].s }
    private var oid: String { order["id"].s }
    private var redacted: Bool { !order.has("items") }
    private var done: Bool { status == "done" || status == "failed" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("🛒 \(order["site"].s)\(order["summary"].truthy ? ": " + order["summary"].s : "")")
                .font(.body.weight(.semibold))
            if redacted {
                Text(TodayOrderLogic.statusLabel[status] ?? status).font(.subheadline).foregroundStyle(.secondary)
                NavigationLink(value: TodayRoute.orders) {
                    Label("中身を見る(Face ID)", systemImage: "faceid").font(.subheadline)
                }
            } else {
                details
            }
        }
        .todayCard(dim: done)
        .alert("注文の確定", isPresented: $askConfirm) {
            Button("注文する") { Task { await checkCardThenApprove() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            let w = deliveryWhen
            Text("この内容で注文を確定します\(w.isEmpty ? "" : "(お届け \(w))")。よろしいですか")
        }
        .alert("カードの PIN", isPresented: $askPin) {
            SecureField("PIN", text: $pin).keyboardType(.numberPad)
            Button("注文する") { let p = pin; pin = ""; Task { await decide(approve: true, pin: p.isEmpty ? nil : p) } }
            Button("キャンセル", role: .cancel) { pin = "" }
        } message: {
            Text("カードで払う場合は PIN を入力(コンビニ払いなどカードを使わないなら空欄で OK)")
        }
        .alert("注文", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private var details: some View {
        ForEach(Array(order["items"].arr.enumerated()), id: \.offset) { _, i in
            let price = i["price"].s
            Text("・\(TodayOrderLogic.itemName(i))\(price.isEmpty ? "" : " " + price)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        if order["total"].truthy {
            Text(order["total"].s).font(.body.weight(.semibold)).padding(.top, 4)
        }
        TodayDeliveryBox(order: order, reload: reload, toast: toast)
        if let a = TodayOrderLogic.arriveText(order) {
            Text("📦 \(a) お届け").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
        }
        let res = order["result"].s
        if !res.isEmpty && (status == "pending" || done) {
            Text(res).font(.caption).foregroundStyle(status == "done" ? Color.secondary : Color.orange)
        }
        if status == "pending" {
            HStack(spacing: 8) {
                Button { askConfirm = true } label: { Text("注文する").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button("やめる") { Task { await decide(approve: false, pin: nil) } }
                    .buttonStyle(.bordered)
            }
            .disabled(busy)
            .padding(.top, 6)
        } else {
            Text(TodayOrderLogic.statusLabel[status] ?? status).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
        if status == "running" {
            HStack(spacing: 8) {
                TextField("3D セキュアのコード(求められたら)", text: $otp)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                Button(otpSent ? "送信済み" : "送る") { Task { await sendOtp() } }
                    .buttonStyle(.bordered)
                    .disabled(otp.isEmpty || otpSent)
            }
            .padding(.top, 6)
        }
        TodayInboxBox(ref: "order:\(oid)", initial: order["inbox"].arr)
    }

    private var deliveryWhen: String {
        let sel = TodayOrderLogic.selectedOptions(order)
        let when = sel.map { $0["date"].s }.filter { !$0.isEmpty }.sorted().last
        let names = sel.map { $0["name"].s }.joined(separator: "・")
        return ((when.map { TodayFmt.md($0) + " " }) ?? "") + names
    }

    private func checkCardThenApprove() async {
        busy = true
        defer { busy = false }
        do {
            let card = try await TodayAPI.send("GET", "/api/card", stepup: true)
            if card.truthy {
                askPin = true
            } else {
                await decide(approve: true, pin: nil)
            }
        } catch {
            if !TodayAPI.isCancelled(error) { errorText = TodayAPI.message(error) }
        }
    }

    private func decide(approve: Bool, pin: String?) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await TodayAPI.send("POST", "/api/orders/\(TodayAPI.seg(oid))/\(approve ? "approve" : "reject")",
                                        body: ["pin": pin.map { .string($0) } ?? .null], stepup: true)
            await reload()
        } catch {
            if !TodayAPI.isCancelled(error) { errorText = TodayAPI.message(error) }
        }
    }

    private func sendOtp() async {
        let code = otp.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        do {
            _ = try await TodayAPI.send("POST", "/api/orders/\(TodayAPI.seg(oid))/otp", body: ["code": .string(code)], stepup: true)
            otpSent = true
        } catch {
            if !TodayAPI.isCancelled(error) { errorText = TodayAPI.message(error) }
        }
    }
}

/// お届け方法(Amazon の確認画面から読んだ配送オプション)。確認待ちのときだけ選べる
struct TodayDeliveryBox: View {
    let order: TodayJSON
    let reload: @MainActor () async -> Void
    let toast: @MainActor (String) -> Void

    var body: some View {
        let dl = order["delivery"]
        let options = dl["options"].arr
        if !options.isEmpty {
            let edit = order["status"].s == "pending"
            let selected = Set(dl["selected"].arr.map(\.s))
            let sel = options.filter { selected.contains($0["key"].s) }
            let when = sel.map { $0["date"].s }.filter { !$0.isEmpty }.sorted().last
            let groups = options.reduce(into: [String]()) { acc, x in
                let g = x["group"].s
                if !acc.contains(g) { acc.append(g) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("お届け: ").font(.caption).foregroundStyle(.secondary)
                    + Text("\(when.map { TodayFmt.md($0) + " " } ?? "")\(sel.map { $0["name"].s }.joined(separator: "・"))")
                        .font(.caption.weight(.bold))
                if edit {
                    ForEach(Array(groups.enumerated()), id: \.offset) { gi, g in
                        if groups.count > 1 {
                            Text("発送 \(gi + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(options.filter { $0["group"].s == g }.enumerated()), id: \.offset) { _, x in
                            option(x, on: selected.contains(x["key"].s))
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func option(_ x: TodayJSON, on: Bool) -> some View {
        Button {
            guard !on else { return }
            Task {
                do {
                    _ = try await TodayAPI.send("POST", "/api/orders/\(TodayAPI.seg(order["id"].s))/delivery",
                                                body: ["key": .string(x["key"].s)], stepup: true)
                } catch {
                    if !TodayAPI.isCancelled(error) { toast("お届け方法を変えられませんでした") }
                }
                await reload()
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? TodayColors.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(x["label"].s).font(.subheadline.weight(.semibold))
                        + Text(" " + x["name"].s).font(.caption).foregroundStyle(.secondary))
                    if x["cutoff"].truthy {
                        Text("⏱ \(x["cutoff"].s)").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
                Text(x["price"].s).font(.caption)
                    .foregroundStyle(x["price_yen"].truthy ? Color.orange : Color.secondary)
            }
            .padding(8)
            .background((on ? TodayColors.accent.opacity(0.12) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Claude への伝言(ref ごと)。メインのセッションに打ち込まれる(届いたら ✓、届けられない間は「保留中」)
struct TodayInboxBox: View {
    let ref: String
    let initial: [TodayJSON]
    @State private var msgs: [TodayJSON]?
    @State private var text = ""
    @State private var sending = false
    @State private var errorText: String? { didSet { showError = errorText != nil } }
    @State private var showError = false

    static let statusLabel = ["delivered": "✓", "pending": "保留中", "sending": "送信中", "failed": "⚠ 届かず"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array((msgs ?? initial).enumerated()), id: \.offset) { _, m in
                line(m)
            }
            HStack(spacing: 8) {
                TextField("Claude に伝える", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                Button("送信") { Task { await send() } }
                    .buttonStyle(.bordered)
                    .disabled(sending || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.top, 8)
        .alert("送れませんでした", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func line(_ m: TodayJSON) -> some View {
        let st = m["status"].s
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("💬 \(m["text"].s)").font(.caption)
            Text(TodayFmt.hm(m["ts"].s)).font(.caption2).foregroundStyle(.secondary)
            if let l = Self.statusLabel[st] {
                Text(l).font(.caption2).foregroundStyle(st == "failed" ? Color.orange : Color.secondary)
            }
        }
    }

    private func send() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let m = try await TodayAPI.send("POST", "/api/inbox", body: ["text": .string(t), "ref": .string(ref)], signed: true)
            msgs = (msgs ?? initial) + [m]
            text = ""
            // 届いたかを反映
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await reloadMsgs()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await reloadMsgs()
            }
        } catch {
            if TodayAPI.isCancelled(error) { return }
            errorText = TodayAPI.status(error) == 429 ? "少し間を空けて送ってください" : "送れませんでした"
        }
    }

    private func reloadMsgs() async {
        if let v = try? await TodayAPI.get("/api/inbox", query: ["ref": ref]), case .array(let a) = v {
            msgs = a
        }
    }
}

/// 「注文」画面: 確認待ち・処理中と、最近 2 週間に終わった注文(Face ID で中身を見る)
struct TodayOrdersView: View {
    @State private var list: [TodayJSON]?
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let error {
                    TodayLoadError(message: error) { Task { await load() } }
                } else if let list {
                    if list.isEmpty {
                        TodayEmpty(text: "最近の注文はありません")
                    }
                    ForEach(Array(list.enumerated()), id: \.offset) { _, o in
                        TodayOrderCard(order: o, reload: { await load() }, toast: { toast = $0 })
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle("注文")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if list == nil { await load() } }
        .todayToast($toast)
    }

    private func load() async {
        do {
            let od = try await TodayAPI.send("GET", "/api/orders", stepup: true)
            list = od["pending"].arr + od["recent"].arr
            error = nil
        } catch {
            if TodayAPI.isCancelled(error) && list != nil { return }
            self.error = TodayAPI.message(error)
        }
    }
}
