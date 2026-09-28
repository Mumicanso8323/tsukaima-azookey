import SwiftUI
import UniformTypeIdentifiers

// 出費(今月・先月の TRPG と分類別 + PayPay 履歴 CSV の取り込み)と、分割・リボ(Web 版 spendCard / installmentsCard)

// MARK: - 出費

struct SLSpendCard: View {
    let s: SLJSON
    let reload: () async -> Void
    @State private var importing = false
    @State private var importMsg = ""

    var body: some View {
        let t0 = s["this"]["TRPG"].double ?? 0, t1 = s["last"]["TRPG"].double ?? 0
        let trpg = s["trpg"].array
        let maxV = max(1, trpg.map { $0[1].double ?? 0 }.max() ?? 1)
        let cats = s["this"].object.map { ($0.key, $0.value.double ?? 0) }.sorted { $0.1 > $1.1 }
            .map { "\($0.0) \(SLFmt.yen($0.1))" }.joined(separator: " · ")
        let recent = s["recent_trpg"].array
        SLHeader(title: "出費")
        SLCard {
            HStack {
                Text("🎲 今月の TRPG \(SLFmt.yen(t0))").bold()
                Spacer()
                SLSub("先月 \(SLFmt.yen(t1))")
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(trpg.enumerated()), id: \.offset) { _, x in
                    let v = x[1].double ?? 0
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                            .frame(height: max(1, CGFloat(44 * v / maxV)))
                        let ym = x[0].text
                        SLSub(ym.count >= 7 ? "\(Int(ym.suffix(2)) ?? 0)月" : ym)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 64, alignment: .bottom)
            SLSub("今月の内訳: \(cats.isEmpty ? "なし" : cats)")
            if !recent.isEmpty {
                SLDisclosure("最近の TRPG の買い物 \(recent.count) 件") {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, x in
                        SLSub("・\(SLFmt.md(x["day"].string)) \(x["shop"].text) \(x["item"].text) \(x["approx"].truthy ? "約" : "")\(SLFmt.yen(x["jpy"]))")
                    }
                }
            }
            Button { importing = true } label: {
                Label("PayPay 履歴CSVを取り込む", systemImage: "doc.text").font(.footnote)
            }
            .buttonStyle(.bordered)
            .padding(.top, 6)
            if !importMsg.isEmpty { SLSub(importMsg) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            Task { await importCSV(url) }
        }
    }

    private func importCSV(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { importMsg = "ファイルを読めませんでした"; return }
        importMsg = "取り込み中…"
        do {
            let raw = try await TsukaimaAPI.shared.upload("/api/spend/import", data: data, filename: url.lastPathComponent,
                                                          mime: "text/csv", fields: [:])
            let r = SLMoneyJSON.from(raw)
            var parts = ["✓ 取り込み \(r["inserted"].text) 件"]
            if r["duplicates"].truthy { parts.append("重複 \(r["duplicates"].text) 件") }
            if r["skipped"].truthy { parts.append("対象外 \(r["skipped"].text) 件") }
            var msg = parts.joined(separator: " · ")
            if r["period"].truthy { msg += " (\(SLFmt.md(r["period"]["from"].string))〜\(SLFmt.md(r["period"]["to"].string)))" }
            importMsg = msg
        } catch {
            if let st = SLError.status(error), st == 401 || st == 403 {
                importMsg = "取り込めませんでした(CSV の取り込みは Tailscale 接続中だけ使えます)"
            } else {
                importMsg = "取り込めませんでした(列を確認してください)"
            }
        }
        await reload()
    }
}

/// upload の戻り値(Any)を SLJSON に読み直す
enum SLMoneyJSON {
    static func from(_ any: Any) -> SLJSON {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any),
              let j = try? JSONDecoder().decode(SLJSON.self, from: data) else { return .null }
        return j
    }
}

// MARK: - 分割・リボ(数字ごとに 確定/予定/計算値/推測 のバッジ。合計は中身の一番弱いもの)

struct SLCert: View {
    let status: String
    static let labels = ["confirmed": "確定", "scheduled": "予定", "computed": "計算値", "guessed": "推測"]

    var body: some View {
        if let label = Self.labels[status] {
            let (bg, fg, dashed) = Self.style(status)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(bg))
                .overlay(Capsule().strokeBorder(status == "computed" ? Color.accentColor : dashed ? Color.secondary : .clear,
                                                style: StrokeStyle(lineWidth: 1, dash: dashed ? [3] : [])))
                .foregroundStyle(fg)
        }
    }

    private static func style(_ status: String) -> (Color, Color, Bool) {
        switch status {
        case "confirmed": return (SLColors.ok, .white, false)
        case "scheduled": return (.accentColor, .white, false)
        case "computed": return (Color.accentColor.opacity(0.15), .accentColor, false)
        default: return (.clear, .secondary, true)
        }
    }
}

/// 金額 + 確かさ。値が無ければ「不明」
struct SLFig: View {
    let f: SLJSON
    var money = true

    var body: some View {
        if f.truthy {
            HStack(spacing: 4) {
                Text(money ? SLFmt.yen(f["amount"]) : f["amount"].text)
                SLCert(status: f["status"].text)
            }
        } else {
            Text("不明").foregroundStyle(.secondary)
        }
    }
}

struct SLInstallmentsCard: View {
    let d: SLJSON
    let reload: () async -> Void
    @State private var reading = false
    @State private var readMsg = ""

    private static let siteState = ["needs_creds": "ログイン情報が未登録", "not_run": "まだ読んでいません", "ok": "読み取り済み",
                                    "needs_2fa": "本人確認(SMS など)で止まりました", "error": "読み取りに失敗",
                                    "unreadable": "項目を読み取れませんでした"]

    private func mon(_ ym: String) -> String { ym.count >= 7 ? "\(Int(ym.suffix(2)) ?? 0)月" : ym }

    private func breakdown(_ m: SLJSON) -> String {
        let order = ["confirmed", "scheduled", "computed", "guessed"]
        let by = m["by_status"]
        var parts = order.compactMap { k -> String? in
            by[k].truthy ? "\(SLCert.labels[k] ?? k) \(SLFmt.yen(by[k]))" : nil
        }
        let unknown = m["unknown"].array.count
        if unknown > 0 { parts.append("月額が不明 \(unknown) 件(合計に含まず)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SLHeader(title: "分割・リボ")
        SLCard {
            SLSub("分割・リボ 今月(\(mon(d["this"]["ym"].text)))の支払い合計")
            HStack(spacing: 6) {
                Text(SLFmt.yen(d["this"]["total"]["amount"])).font(.system(size: 26, weight: .bold).monospacedDigit())
                SLCert(status: d["this"]["total"]["status"].text)
            }
            let b0 = breakdown(d["this"])
            if !b0.isEmpty { SLSub(b0) }
            HStack {
                SLSub("来月(\(mon(d["next"]["ym"].text)))")
                Spacer()
                Text(SLFmt.yen(d["next"]["total"]["amount"]))
                SLCert(status: d["next"]["total"]["status"].text)
            }
            .padding(.top, 4)
            let b1 = breakdown(d["next"])
            if !b1.isEmpty { SLSub(b1) }
            HStack {
                SLSub("残高の合計")
                Spacer()
                SLFig(f: d["balance"])
            }
            .padding(.top, 4)
            if d["balance_unknown"].truthy { SLSub("残高が不明 \(d["balance_unknown"].text) 件(合計に含まず)") }

            ForEach(Array(d["cards"].array.enumerated()), id: \.offset) { _, c in
                SLInstallmentCardGroup(c: c)
            }

            let bills = d["bills"].array
            if !bills.isEmpty {
                SLDisclosure("カードの請求・支払日(1 回払いも含む)") {
                    ForEach(Array(bills.enumerated()), id: \.offset) { _, b in
                        HStack(spacing: 4) {
                            SLSub("・\(SLFmt.md(b["due"].string)) \(b["card_name"].text)")
                            if b["amount"].isNull {
                                SLSub("支払日"); SLCert(status: b["status"].text); SLSub("(金額は未取得)")
                            } else {
                                SLSub(SLFmt.yen(b["amount"])); SLCert(status: b["status"].text)
                            }
                        }
                    }
                }
            }
            let sites = d["sites"].array
            SLDisclosure("カード会社の明細の読み取り") {
                ForEach(Array(sites.enumerated()), id: \.offset) { _, x in
                    let st = x["state"].text
                    SLSub("・\(x["name"].text): \(Self.siteState[st] ?? st)\(x["at"].truthy && st != "needs_creds" ? "(\(SLFmt.md(x["at"].string)))" : "")")
                }
                SLSub("ログイン情報は 設定 → ログイン情報の金庫 に、サイト名 vpass / orico / jcb / paypaycard で登録します。読むだけで、設定や支払い方法は変えません。")
                    .padding(.top, 4)
                if sites.contains(where: { $0["has_creds"].truthy }) {
                    HStack {
                        Button("今すぐ読む") { Task { await readNow() } }
                            .buttonStyle(.bordered).controlSize(.small).disabled(reading)
                        if !readMsg.isEmpty { SLSub(readMsg) }
                    }
                    .padding(.top, 4)
                }
            }
            // 凡例
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) { SLCert(status: "confirmed"); SLSub("明細から"); SLCert(status: "scheduled"); SLSub("カード会社の予告") }
                HStack(spacing: 4) { SLCert(status: "computed"); SLSub("条件からの計算"); SLCert(status: "guessed"); SLSub("古い値・仮定を含む") }
            }
            .padding(.top, 8)
        }
    }

    private func readNow() async {
        reading = true
        readMsg = "読んでいます…(1〜2 分)"
        do {
            try await SLAPI.post("/api/installments/read", stepup: true)
            readMsg = ""
            await reload()
        } catch {
            readMsg = SLError.message(error, fallback: "読めませんでした")
        }
        reading = false
    }
}

/// カードごとの折りたたみ(今月・来月・残高と、その中の分割/リボの各件)
private struct SLInstallmentCardGroup: View {
    let c: SLJSON
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    SLSub("来月")
                    if c["next_month"].truthy { SLFig(f: c["next_month"]).font(.footnote) } else { SLSub("—") }
                    SLSub("· 残高")
                    SLFig(f: c["balance"]).font(.footnote)
                }
                ForEach(Array(c["items"].array.enumerated()), id: \.offset) { _, i in
                    Divider()
                    item(i)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(c["name"].text).bold().foregroundStyle(.primary)
                Spacer()
                SLSub("今月")
                if c["this_month"].truthy { SLFig(f: c["this_month"]).font(.footnote) } else { SLSub("—") }
            }
        }
        .tint(.secondary)
        .padding(.top, 6)
    }

    @ViewBuilder private func item(_ i: SLJSON) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(i["kind"].text == "リボ" ? "🔁 " : "")\(i["item"].text)").lineLimit(1)
                Spacer()
                SLSub("月")
                SLFig(f: i["monthly"]).font(.footnote)
                if i["first_amount"].truthy { SLSub("(初回 \(SLFmt.yen(i["first_amount"])))") }
            }
            HStack(spacing: 4) {
                let head = [i["purchase_date"].truthy ? "\(SLFmt.md(i["purchase_date"].string)) 購入" : "",
                            i["n_payments"].truthy ? "\(i["n_payments"].text) 回払い" : i["kind"].text].filter { !$0.isEmpty }
                SLSub(head.joined(separator: " · "))
                if i["months_left"].truthy {
                    SLSub("· 残り \(i["months_left"]["amount"].text) 回"); SLCert(status: i["months_left"]["status"].text)
                }
                if i["next_date"].truthy {
                    SLSub("· 次回 \(SLFmt.md(i["next_date"]["amount"].string))"); SLCert(status: i["next_date"]["status"].text)
                }
            }
            HStack(spacing: 4) {
                SLSub("残高")
                SLFig(f: i["balance"]).font(.footnote)
                let tail = [i["as_of"].truthy && i["balance"].truthy ? "(\(SLFmt.md(i["as_of"].string)) 時点)" : "",
                            i["apr"].truthy ? "実質年率 \(i["apr"].text)%" : "",
                            i["fee"].truthy ? "手数料 \(SLFmt.yen(i["fee"]))" : ""].filter { !$0.isEmpty }
                if !tail.isEmpty { SLSub(tail.joined(separator: " · ")) }
            }
            if i["note"].truthy { SLSub(i["note"].text).font(.caption) }
        }
    }
}
