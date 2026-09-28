import SwiftUI

// 注文(Web 版 tabs.orders / orderCard / bindOrders)。注文データの閲覧・承認・お届け方法・3D セキュアのコードは
// サーバが require_stepup なので、すべて stepup: true(Face ID)で叩く。「Claude に伝える」は端末署名(signed)。

private let SLOrderStatus = ["pending": "確認待ち", "approved": "確定待ち", "running": "注文中…", "done": "注文済み", "failed": "失敗"]

struct SLOrdersView: View {
    @State private var orders: [SLJSON]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let orders {
                    if orders.isEmpty { SLEmpty("最近の注文はありません") }
                    ForEach(orders, id: \.self) { o in
                        SLOrderCard(order: o) { await load() }
                    }
                } else {
                    SLLoadState(error: error) { Task { await load() } }
                }
            }
            .padding(16)
        }
        .navigationTitle("注文")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let od = try await SLAPI.getStepup("/api/orders")
            orders = od["pending"].array + od["recent"].array
            error = nil
        } catch {
            self.error = SLError.message(error)
        }
    }
}

struct SLOrderCard: View {
    let order: SLJSON
    let changed: () async -> Void

    @State private var otp = ""
    @State private var otpSent = false
    @State private var busy = false
    @State private var confirmApprove = false
    @State private var askPin = false
    @State private var pin = ""
    @State private var message: String?

    private var id: String { order["id"].text }
    private var status: String { order["status"].text }
    private var done: Bool { status == "done" || status == "failed" }

    /// 結果の「9/27(日) お届け」
    private var arrive: String? {
        let res = order["result"].text
        guard let r = res.range(of: #"(\d{1,2}/\d{1,2}(?:\([月火水木金土日]\))?) お届け"#, options: .regularExpression) else { return nil }
        return String(res[r]).replacingOccurrences(of: " お届け", with: "")
    }

    var body: some View {
        SLCard(accent: !done) {
            Text("🛒 \(order["site"].text): \(order["summary"].text)").bold()
            ForEach(Array(order["items"].array.enumerated()), id: \.offset) { _, i in
                let name = i["name"].string ?? i.text
                SLSub("・\(name)\(i["price"].truthy ? " " + i["price"].text : "")")
            }
            if order["total"].truthy { Text(order["total"].text).bold().padding(.top, 4) }
            SLDelivery(order: order, editable: status == "pending") { key in await setDelivery(key) }
            if let arrive {
                Text("📦 \(arrive) お届け").font(.headline).foregroundStyle(SLColors.ok).padding(.top, 4)
            }
            let res = order["result"].text
            if !res.isEmpty && (status == "pending" || done) {
                Text(res).font(.footnote).foregroundStyle(status == "done" ? Color.secondary : SLColors.imp3)
            }
            if status == "pending" {
                HStack {
                    Button { confirmApprove = true } label: {
                        Text("注文する").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("やめる") { Task { await decide(approve: false, pin: nil) } }
                        .buttonStyle(.bordered)
                }
                .disabled(busy)
                .padding(.top, 6)
            } else {
                SLSub(SLOrderStatus[status] ?? status).padding(.top, 4)
            }
            if status == "running" {
                HStack {
                    TextField("3D セキュアのコード(求められたら)", text: $otp)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .textFieldStyle(.roundedBorder)
                    Button(otpSent ? "送信済み" : "送る") { Task { await sendOTP() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(otp.isEmpty || busy)
                }
                .padding(.top, 6)
            }
            SLInboxBox(ref: "order:\(id)", initial: order["inbox"].array)
        }
        .opacity(done ? 0.8 : 1)
        .confirmationDialog(approveText, isPresented: $confirmApprove, titleVisibility: .visible) {
            Button("注文する") { Task { await beginApprove() } }
            Button("やめておく", role: .cancel) {}
        }
        .alert("カードで払う場合は PIN を入力", isPresented: $askPin) {
            SecureField("PIN", text: $pin).keyboardType(.numberPad)
            Button("注文する") { let p = pin; pin = ""; Task { await decide(approve: true, pin: p.isEmpty ? nil : p) } }
            Button("やめる", role: .cancel) { pin = "" }
        } message: {
            Text("コンビニ払いなどカードを使わないなら空欄で OK")
        }
        .slToast($message)
    }

    private var approveText: String {
        let w = SLDelivery.when(order)
        return "この内容で注文を確定します\(w.isEmpty ? "" : "(お届け \(w))")。よろしいですか"
    }

    /// カードが登録されていれば PIN を聞く(Web 版と同じ)
    private func beginApprove() async {
        busy = true
        let card = try? await SLAPI.getStepup("/api/card")
        busy = false
        if let card, card.truthy {
            askPin = true
        } else {
            await decide(approve: true, pin: nil)
        }
    }

    private func decide(approve: Bool, pin: String?) async {
        busy = true
        defer { busy = false }
        do {
            try await SLAPI.post("/api/orders/\(id)/\(approve ? "approve" : "reject")",
                                 ["pin": pin.map { .s($0) } ?? .null], stepup: true)
        } catch {
            message = SLError.message(error)
            return
        }
        await changed()
    }

    private func setDelivery(_ key: String) async {
        do { try await SLAPI.post("/api/orders/\(id)/delivery", ["key": .s(key)], stepup: true) }
        catch { message = "お届け方法を変えられませんでした" }
        await changed()
    }

    private func sendOTP() async {
        busy = true
        defer { busy = false }
        do {
            try await SLAPI.post("/api/orders/\(id)/otp", ["code": .s(otp)], stepup: true)
            otpSent = true
        } catch {
            message = SLError.message(error)
        }
    }
}

/// お届け方法(Amazon の確認画面から読んだ配送オプション)。確認待ちのときだけ選べる
struct SLDelivery: View {
    let order: SLJSON
    let editable: Bool
    let select: (String) async -> Void

    static func when(_ o: SLJSON) -> String {
        let dl = o["delivery"]
        let selected = Set(dl["selected"].array.map(\.text))
        let sel = dl["options"].array.filter { selected.contains($0["key"].text) }
        let date = sel.map { $0["date"].text }.filter { !$0.isEmpty }.sorted().last
        let names = sel.map { $0["name"].text }.joined(separator: "・")
        return [date.map { SLFmt.md($0) } ?? "", names].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func groups(_ options: [SLJSON]) -> [String] {
        var out: [String] = []
        for o in options where !out.contains(o["group"].text) { out.append(o["group"].text) }
        return out
    }

    var body: some View {
        let dl = order["delivery"]
        let options = dl["options"].array
        if !options.isEmpty {
            let selected = Set(dl["selected"].array.map(\.text))
            let groups = Self.groups(options)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    SLSub("お届け:")
                    Text(Self.when(order)).font(.footnote.bold())
                }
                if editable {
                    ForEach(groups, id: \.self) { g in
                        if groups.count > 1 { SLSub("発送 \((Int(g) ?? 0) + 1)") }
                        ForEach(options.filter { $0["group"].text == g }, id: \.self) { x in
                            let on = selected.contains(x["key"].text)
                            Button { Task { await select(x["key"].text) } } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: on ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(on ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(x["label"].text).font(.subheadline)
                                            SLSub(x["name"].text)
                                        }
                                        if x["cutoff"].truthy {
                                            Text("⏱ \(x["cutoff"].text)").font(.footnote).foregroundStyle(SLColors.imp2)
                                        }
                                    }
                                    Spacer()
                                    Text(x["price"].text).font(.footnote.weight(x["price_yen"].truthy ? .semibold : .regular))
                                        .foregroundStyle(x["price_yen"].truthy ? SLColors.imp2 : .secondary)
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.accentColor.opacity(0.12) : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Color.accentColor : Color(.separator), lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

/// Claude への伝言(ref ごと)。メインのセッションに打ち込まれる(届いたら ✓、届けられない間は「保留中」)
struct SLInboxBox: View {
    let ref: String
    let initial: [SLJSON]

    @State private var msgs: [SLJSON]?
    @State private var text = ""
    @State private var sending = false
    @State private var message: String?

    private static let st = ["delivered": "✓", "pending": "保留中", "sending": "送信中", "failed": "⚠ 届かず"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array((msgs ?? initial).enumerated()), id: \.offset) { _, m in
                let s = m["status"].text
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("💬 \(m["text"].text)").font(.footnote)
                    Text(SLFmt.hm(m["ts"].string)).font(.caption2).foregroundStyle(.secondary)
                    if let label = Self.st[s] {
                        Text(label).font(.caption2)
                            .foregroundStyle(s == "delivered" ? SLColors.ok : s == "failed" ? SLColors.imp3 : SLColors.imp2)
                    }
                }
            }
            HStack {
                TextField("Claude に伝える", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                Button("送信") { Task { await send() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sending || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.top, 8)
        .slToast($message)
    }

    private func send() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let m = try await SLAPI.post("/api/inbox", ["text": .s(t), "ref": .s(ref)], signed: true)
            msgs = (msgs ?? initial) + [m]
            text = ""
        } catch {
            message = SLError.message(error, fallback: "送れませんでした")
            return
        }
        // 届いたかを反映
        Task {
            try? await Task.sleep(for: .seconds(2)); await reload()
            try? await Task.sleep(for: .seconds(10)); await reload()
        }
    }

    private func reload() async {
        if let r = try? await SLAPI.get("/api/inbox", query: ["ref": ref]) { msgs = r.array }
    }
}
