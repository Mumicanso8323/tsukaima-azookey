import SwiftUI

// 買い物リスト(Web 版 tabs.shop)とイヤホン比較(tabs.earphones)

private func slStars(_ r: SLJSON, _ n: SLJSON, unknown: String = "") -> String {
    guard r.truthy else { return unknown }
    return "★\(r.text)\(n.truthy ? "(\(SLFmt.grouped(n.double ?? 0)))" : "")"
}

/// 商品画像(Amazon の画像 URL。認証不要なので AsyncImage)
private struct SLProductImage: View {
    let url: String
    var size: CGFloat = 88

    var body: some View {
        AsyncImage(url: URL(string: url)) { img in
            img.resizable().scaledToFit()
        } placeholder: {
            Color.clear
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 買い物リスト

struct SLShopView: View {
    @State private var items: [SLJSON]?
    @State private var error: String?
    @State private var message: String?
    @State private var preparing = false
    @State private var prepared = false
    @State private var busy = false
    @Environment(\.openURL) private var openURL

    private static let statusLabel: [(String, String)] = [("want", "欲しい"), ("bought", "買った"), ("skip", "要らない")]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let items {
                    content(items)
                } else {
                    SLLoadState(error: error) { Task { await load() } }
                }
            }
            .padding(16)
        }
        .navigationTitle("買い物リスト")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .slToast($message)
    }

    private func pickOf(_ it: SLJSON) -> SLJSON? {
        it["candidates"].array.first { $0["asin"].text == it["pick"].text && it["pick"].truthy }
    }

    @ViewBuilder private func content(_ items: [SLJSON]) -> some View {
        let active = items.filter { $0["status"].text != "bought" && $0["status"].text != "skip" }
        let bought = items.filter { $0["status"].text == "bought" }
        let skipped = items.filter { $0["status"].text == "skip" }
        let picked = active.filter { $0["pick"].truthy && $0["status"].text == "want" }
        if !picked.isEmpty {
            let sum = picked.reduce(0.0) { $0 + (pickOf($1)?["price"].double ?? 0) }
            SLCard(accent: true) {
                Text("選んだ物 \(picked.count) 点 · 約 \(SLFmt.yen(sum))").bold()
                SLSub("カートに入れて、オリコ分割(月 400 円以下になる回数)の確認画面まで進めます。確定は「注文」の「注文する」+ PIN。カートにある他の商品は「後で買う」に移します。")
                Button(preparing ? "準備中…(1〜2 分。できたら通知します)" : prepared ? "準備を始めました(できたら通知します)" : "注文の準備をする") {
                    Task { await prepare() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(preparing || prepared)
                .padding(.top, 4)
            }
        }
        SLSub("購入履歴・睡眠・ダイエット・授業録音の課題から選びました。価格は取得時点。リンクは Amazon の商品ページ(アプリで開く)。")
        NavigationLink(value: SLLifeRoute.earphones) {
            SLLinkRow(icon: "🎧", title: "イヤホン比較", sub: "ノイキャン・寝ホン・音質で採点")
        }
        .buttonStyle(.plain)
        ForEach(Array(active.enumerated()), id: \.offset) { i, it in
            if i == 0 || active[i - 1]["tier"].text != it["tier"].text {
                SLHeader(title: it["tier"].text)
            }
            itemCard(it)
        }
        if active.isEmpty { SLEmpty("まだありません") }
        if !bought.isEmpty {
            SLHeader(title: "買った")
            ForEach(Array(bought.enumerated()), id: \.offset) { _, it in
                SLCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("✅ \(it["name"].text)").bold()
                            if let c = pickOf(it) { SLSub("\(c["title"].text) \(c["price"].truthy ? SLFmt.yen(c["price"]) : "")") }
                        }
                        Spacer()
                        Button("戻す") { Task { await mark(it["id"].text, "") } }.buttonStyle(.bordered).disabled(busy)
                    }
                }
                .opacity(0.55)
            }
        }
        if !skipped.isEmpty {
            SLDisclosure("要らない (\(skipped.count))") {
                ForEach(Array(skipped.enumerated()), id: \.offset) { _, it in
                    HStack {
                        Text(it["name"].text)
                        Spacer()
                        Button("戻す") { Task { await mark(it["id"].text, "") } }.buttonStyle(.bordered).disabled(busy)
                    }
                    .opacity(0.6)
                    .padding(.vertical, 2)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func itemCard(_ it: SLJSON) -> some View {
        let id = it["id"].text
        let st = it["status"].text
        SLCard {
            HStack(alignment: .firstTextBaseline) {
                Text("\(id). \(it["name"].text)").bold()
                Spacer()
                if let l = Self.statusLabel.first(where: { $0.0 == st }) { SLSub(l.1) }
            }
            SLSub(it["why"].text)
            ForEach(Array(it["candidates"].array.enumerated()), id: \.offset) { _, c in
                let chosen = it["pick"].truthy && it["pick"].text == c["asin"].text
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if let u = URL(string: c["url"].text) { openURL(u) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            SLProductImage(url: c["image"].text)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c["title"].text).font(.subheadline).foregroundStyle(.primary).lineLimit(4)
                                SLSub("\(c["price"].truthy ? SLFmt.yen(c["price"]) : "") \(slStars(c["rating"], c["review_count"]))")
                                if c["note"].truthy { SLSub(c["note"].text) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Button(chosen ? "✓ これにする(解除)" : "これにする") {
                        Task { await pick(id, chosen ? "" : c["asin"].text) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                .padding(chosen ? 4 : 0)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(chosen ? Color.orange : .clear, lineWidth: 2))
                .padding(.vertical, 4)
            }
            HStack(spacing: 6) {
                ForEach(Self.statusLabel, id: \.0) { k, l in
                    Button(l) { Task { await mark(id, st == k ? "" : k) } }
                        .buttonStyle(.bordered)
                        .tint(st == k ? .accentColor : .secondary)
                        .controlSize(.small)
                        .disabled(busy)
                }
            }
            .padding(.top, 4)
        }
    }

    private func load() async {
        do { items = try await SLAPI.get("/api/shopping").array; error = nil }
        catch { self.error = SLError.message(error) }
    }

    private func mark(_ id: String, _ status: String) async {
        busy = true
        defer { busy = false }
        do { try await SLAPI.post("/api/shopping/\(SLAPI.escape(id))", ["status": .s(status)], stepup: true) }
        catch { message = SLError.message(error) }
        await load()
    }

    private func pick(_ id: String, _ asin: String) async {
        busy = true
        defer { busy = false }
        do { try await SLAPI.post("/api/shopping/\(SLAPI.escape(id))/pick", ["asin": .s(asin)], stepup: true) }
        catch { message = SLError.message(error) }
        await load()
    }

    private func prepare() async {
        preparing = true
        defer { preparing = false }
        do {
            try await SLAPI.post("/api/shopping/prepare", stepup: true)
            prepared = true
        } catch {
            message = SLError.message(error)
        }
    }
}

// MARK: - イヤホン比較

struct SLEarphonesView: View {
    @State private var doc: SLJSON?
    @State private var error: String?
    @State private var message: String?
    @Environment(\.openURL) private var openURL

    static let axes: [(String, String)] = [("anc", "ノイキャン"), ("sound", "音質/ASMR"), ("sleep", "寝ホン適性"),
                                           ("durability", "丈夫さ"), ("battery", "電池"), ("value", "コスパ")]
    static let specLabels: [(String, String)] = [("anc", "ANC"), ("battery_earbud", "本体電池"), ("battery_case", "ケース込み"),
                                                 ("codec", "コーデック"), ("water_resistance", "防水"), ("weight", "重さ/サイズ"),
                                                 ("sleep_fit", "寝ホン適性(仕様)")]
    static let scoreColors: [Color] = [.clear,
                                       Color(red: 0xc9 / 255, green: 0x3b / 255, blue: 0x3b / 255),
                                       Color(red: 0xd9 / 255, green: 0x7a / 255, blue: 0x1e / 255),
                                       Color(red: 0xc9 / 255, green: 0xa5 / 255, blue: 0x20 / 255),
                                       Color(red: 0x5a / 255, green: 0x9e / 255, blue: 0x3f / 255),
                                       Color(red: 0x1f / 255, green: 0x9d / 255, blue: 0x55 / 255)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let doc {
                    tldr(doc["tldr"])
                    SLSub("スコアは5段階の色チップ(赤=弱い〜緑=強い)。実際にAmazonの商品ページ・出品情報で見た内容だけを記載し、確認できなかった項目は「不明」としています。")
                    let items = doc["items"].array
                    if items.isEmpty { SLEmpty("まだありません") }
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in card(it) }
                } else {
                    SLLoadState(error: error) { Task { await load() } }
                }
            }
            .padding(16)
        }
        .navigationTitle("イヤホン比較")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .slToast($message)
    }

    @ViewBuilder private func tldr(_ t: SLJSON) -> some View {
        SLCard(accent: true) {
            Text("TL;DR").bold()
            SLSub("🏆 総合: \(t["best_overall"].truthy ? t["best_overall"].text : "不明")")
            SLSub("😴 寝ホン向け: \(t["best_sleep"].truthy ? t["best_sleep"].text : "不明")")
            SLSub("💰 予算重視: \(t["best_budget"].truthy ? t["best_budget"].text : "不明")")
            if t["purchase_order"].truthy {
                SLSub("購入順の目安: \(t["purchase_order"].array.map(\.text).joined(separator: " → "))").padding(.top, 4)
            }
            if t["note"].truthy { SLSub(t["note"].text).padding(.top, 4) }
        }
    }

    @ViewBuilder private func card(_ it: SLJSON) -> some View {
        let sp = it["specs"], sc = it["scores"], rs = it["reasons"]
        SLCard {
            HStack(alignment: .top, spacing: 10) {
                Button { if let u = URL(string: it["url"].text) { openURL(u) } } label: {
                    SLProductImage(url: it["image"].text, size: 76)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Text(it["name"].text).bold()
                        Spacer()
                        Button(it["want"].truthy ? "♥ 欲しい" : "♡ 欲しい") { Task { await want(it) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    SLSub("\(it["price"].truthy ? SLFmt.yen(it["price"]) : "不明") ・ \(slStars(it["rating"], it["review_count"], unknown: "不明"))")
                    if it["category_label"].truthy { SLSub(it["category_label"].text) }
                }
            }
            SLFlow(spacing: 6) {
                ForEach(Self.axes, id: \.0) { k, label in
                    let s = min(5, max(0, sc[k].int ?? 0))
                    Text("\(label) \(s > 0 ? String(repeating: "●", count: s) + String(repeating: "○", count: 5 - s) : "不明")")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Self.scoreColors[s]))
                        .overlay(Capsule().strokeBorder(s == 0 ? Color.secondary : .clear, style: StrokeStyle(lineWidth: 1, dash: [3])))
                        .foregroundStyle(s == 0 ? Color.secondary : s == 3 ? Color.black : Color.white)
                }
            }
            .padding(.vertical, 4)
            SLDisclosure("詳細・スペック・採点理由") {
                ForEach(Self.specLabels, id: \.0) { k, label in
                    SLSub("\(label): \(sp[k].truthy ? sp[k].text : "不明")")
                }
                Divider()
                ForEach(Self.axes, id: \.0) { k, label in
                    SLSub("\(label)(\(sc[k].truthy ? sc[k].text : "不明")/5): \(rs[k].truthy ? rs[k].text : "不明")")
                }
                if it["asin"].truthy { SLSub("ASIN: \(it["asin"].text)") }
            }
            if let u = URL(string: it["url"].text), it["url"].truthy {
                Link("Amazonで見る →", destination: u).font(.footnote)
            }
        }
    }

    private func load() async {
        do { doc = try await SLAPI.get("/api/earphones"); error = nil }
        catch { self.error = SLError.message(error) }
    }

    private func want(_ it: SLJSON) async {
        do { try await SLAPI.post("/api/earphones/\(SLAPI.escape(it["id"].text))", ["want": .b(!it["want"].truthy)]) }
        catch { message = SLError.message(error) }
        await load()
    }
}
