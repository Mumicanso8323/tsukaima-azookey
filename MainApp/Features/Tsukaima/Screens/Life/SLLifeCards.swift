import SwiftUI

// 生活タブのカード: ヘルスケア・夜の予定の余裕(睡眠)・体重(Web 版 healthCard / nightsCard / weightCard)

enum SLColors {
    static let ok = Color(red: 0x1f / 255, green: 0x9d / 255, blue: 0x55 / 255)
    static let imp2 = Color(red: 0xe0 / 255, green: 0x8a / 255, blue: 0x1e / 255)
    static let imp3 = Color(red: 0xd9 / 255, green: 0x36 / 255, blue: 0x36 / 255)
    static let trpgPL = Color(red: 0x7c / 255, green: 0x5c / 255, blue: 0xbf / 255)
    static let trpgKP = Color(red: 0x5b / 255, green: 0x3a / 255, blue: 0x9e / 255)
    static let trpgOther = Color(red: 0xc9 / 255, green: 0xb8 / 255, blue: 0xec / 255)
    static let trpgText = Color(red: 0x8a / 255, green: 0x6b / 255, blue: 0xd0 / 255)

    static func trpg(_ role: String) -> Color? {
        switch role {
        case "pl": return trpgPL
        case "kp": return trpgKP
        case "other": return trpgOther
        default: return nil
        }
    }
}

/// TRPG の役割チップ(PL / KP / 他)
struct SLTrpgChip: View {
    let role: String
    var body: some View {
        if let c = SLColors.trpg(role) {
            Text(["pl": "PL", "kp": "KP", "other": "他"][role] ?? role)
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(c))
                .foregroundStyle(role == "other" ? Color.black : Color.white)
        }
    }
}

// MARK: - ヘルスケア

struct SLHealthCard: View {
    let rows: [SLJSON]
    let today0: String

    var body: some View {
        if !rows.isEmpty {
            let byDay = Dictionary(rows.map { ($0["day"].text, $0) }, uniquingKeysWith: { a, _ in a })
            let yest0 = SLFmt.isoDay(Calendar.current.date(byAdding: .day, value: -1, to: SLFmt.day(today0) ?? Date()) ?? Date())
            SLHeader(title: "ヘルスケア")
            SLCard {
                HStack(alignment: .firstTextBaseline) {
                    Text("今日").bold().frame(minWidth: 44, alignment: .leading)
                    SLSub(Self.line(byDay[today0]))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("昨日").bold().frame(minWidth: 44, alignment: .leading)
                    SLSub(Self.line(byDay[yest0]))
                }
                if rows.count > 2 {
                    SLDisclosure("過去 \(rows.count) 日") {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                            SLSub("・\(SLFmt.md(r["day"].string)) \(Self.line(r))")
                        }
                    }
                }
            }
        }
    }

    static func line(_ r: SLJSON?) -> String {
        guard let r else { return "記録なし" }
        func f1(_ v: Double) -> String {
            let x = (v * 10).rounded() / 10
            return x == x.rounded() ? String(Int(x)) : String(x)
        }
        func n(_ j: SLJSON) -> String { j.string ?? "" }
        var parts: [String] = []
        if let v = r["steps"].double { parts.append("\(SLFmt.grouped(v)) 歩") }
        if !r["flights"].isNull { parts.append("\(n(r["flights"])) 階") }
        if !r["active_kcal"].isNull { parts.append("活動 \(n(r["active_kcal"])) kcal") }
        if !r["sleep_hours"].isNull { parts.append("睡眠 \(n(r["sleep_hours"]))h") }
        if !r["resting_hr"].isNull { parts.append("安静時 \(n(r["resting_hr"]))") }
        let x = r["extra"]
        if !x["sleep_deep_h"].isNull || !x["sleep_rem_h"].isNull {
            let deep = x["sleep_deep_h"].double.map { f1($0) + "h" } ?? "-"
            let rem = x["sleep_rem_h"].double.map { f1($0) + "h" } ?? "-"
            parts.append("深い \(deep) / レム \(rem)")
        }
        if let avg = x["hr_avg"].double {
            var s = "心拍 平均 \(Int(avg.rounded()))"
            if let lo = x["hr_min"].double, let hi = x["hr_max"].double { s += "(\(Int(lo.rounded()))〜\(Int(hi.rounded())))" }
            parts.append(s)
        }
        if let v = x["hrv_ms"].double { parts.append("HRV \(Int(v.rounded()))ms") }
        if let v = x["spo2"].double { parts.append("SpO2 \(Int((v <= 1 ? v * 100 : v).rounded()))%") }
        if let v = x["weight_kg"].double { parts.append("体重 \(f1(v))kg") }
        // 体組成計(TANITA)の手入力ぶん
        if let v = x["body_fat_pct"].double { parts.append("体脂肪 \(f1(v))%") }
        if let v = x["muscle_kg"].double { parts.append("筋肉 \(f1(v))kg") }
        if !x["visceral_fat"].isNull { parts.append("内臓脂肪 \(n(x["visceral_fat"]))") }
        if !x["bmr_kcal"].isNull { parts.append("基礎代謝 \(n(x["bmr_kcal"]))kcal") }
        return parts.isEmpty ? "記録なし" : parts.joined(separator: " · ")
    }
}

// MARK: - 夜の予定の余裕(翌日の授業から見て、その夜どこまで起きていられるか・2 週間)

struct SLNightsCard: View {
    let data: SLJSON
    private static let verdictLabel = ["free": "休み", "ok": "余裕あり", "tight": "ギリギリ", "ng": "睡眠不足"]

    var body: some View {
        let rows = data["nights"].array
        SLHeader(title: "夜の予定の余裕(2 週間)")
        SLCard {
            if rows.isEmpty { SLEmpty("予定なし") }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, n in
                row(n)
                if i < rows.count - 1 { Divider() }
            }
        }
    }

    @ViewBuilder private func row(_ n: SLJSON) -> some View {
        let verdict = n["verdict"].text
        let trpg = n["trpg"]
        let cls = n["next_class"].truthy ? "\(n["next_class"]["title"].text) \(n["next_class_label"].text)" : "授業なし"
        HStack(alignment: .top, spacing: 0) {
            if let c = SLColors.trpg(trpg["role"].text) {
                Rectangle().fill(c).frame(width: 3).padding(.trailing, 8)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(SLFmt.md(n["date"].string)).font(.subheadline.monospacedDigit()).frame(minWidth: 62, alignment: .leading)
                    verdictChip(verdict)
                    Text(cls).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if verdict != "free" {
                        Text("\(SLFmt.hm(n["bed_ok"].string)) まで").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                let tv = trpg["verdict"].text
                if trpg.truthy && (tv == "tight" || tv == "ng") {
                    HStack(spacing: 4) {
                        Text("⚠ \(trpg["title"].text)(卓)")
                        SLTrpgChip(role: trpg["role"].text)
                        Text("→ 睡眠 約\(trpg["sleep_hours"].text)h")
                    }
                    .font(.footnote)
                    .foregroundStyle(tv == "ng" ? SLColors.imp3 : SLColors.imp2)
                }
                if trpg["kp_prep"].truthy {
                    Text(trpg["kp_prep"]["text"].text).font(.footnote).foregroundStyle(SLColors.trpgText)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func verdictChip(_ v: String) -> some View {
        let label = Self.verdictLabel[v] ?? v
        let color: Color? = v == "ok" ? SLColors.ok : v == "tight" ? SLColors.imp2 : v == "ng" ? SLColors.imp3 : nil
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color ?? .clear))
            .overlay(Capsule().strokeBorder(color == nil ? Color.secondary : .clear, style: StrokeStyle(lineWidth: 1, dash: [3])))
            .foregroundStyle(color == nil ? Color.secondary : Color.white)
    }
}

// MARK: - 体重(最新・7 日前との差・直近 30 件の折れ線)

struct SLWeightCard: View {
    let all: [SLJSON]
    let saved: @MainActor () async -> Void
    @State private var input = ""
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        let w = Array(all.prefix(30).reversed())
        let last = w.last
        let weekAgo = SLFmt.isoDay(Date().addingTimeInterval(-7 * 86400))
        let wk = w.filter { $0["day"].text <= weekAgo }.last
        let diff: Double? = (last?["kg"].double).flatMap { l in (wk?["kg"].double).map { ((l - $0) * 10).rounded() / 10 } }
        SLHeader(title: "体重")
        SLCard {
            HStack(alignment: .firstTextBaseline) {
                if let last {
                    Text("\(last["kg"].text) kg").bold()
                    SLSub(SLFmt.md(last["day"].string))
                } else {
                    Text("まだ記録なし").bold()
                }
                Spacer()
                if let diff {
                    SLSub("1 週間で \(diff > 0 ? "+" : "")\(String(format: "%.1f", diff)) kg")
                }
            }
            let ks = w.compactMap { $0["kg"].double }
            if ks.count >= 2 {
                SLSparkline(values: ks).frame(height: 66).foregroundStyle(Color.accentColor)
            }
            HStack {
                TextField("今日の体重 (kg)", text: $input)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button("記録") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
        }
        .slToast($message)
    }

    private func save() async {
        guard let kg = Double(input.replacingOccurrences(of: ",", with: ".")), kg > 0 else { return }
        saving = true
        defer { saving = false }
        do {
            try await SLAPI.post("/api/weight", ["kg": .d(kg)])
            input = ""
        } catch {
            message = SLError.message(error, fallback: "記録できませんでした")
        }
        await saved()
    }
}

struct SLSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let lo = (values.min() ?? 0) - 0.5, hi = (values.max() ?? 0) + 0.5
            Path { p in
                for (i, k) in values.enumerated() {
                    let x = CGFloat(i) / CGFloat(values.count - 1) * (geo.size.width - 20) + 10
                    let y = geo.size.height - 6 - CGFloat((k - lo) / (hi - lo)) * (geo.size.height - 16)
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
