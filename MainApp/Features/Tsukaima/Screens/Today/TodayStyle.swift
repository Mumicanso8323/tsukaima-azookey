import SwiftUI

/// 今日タブの見た目の部品(web 版 style.css の card / badge / chip / h2 に相当)。
enum TodayColors {
    static let card = Color(.secondarySystemBackground)
    static let sub = Color.secondary
    static let accent = Color.accentColor
    static let hot = Color.red
    static let warm = Color.orange
    static let trpgPL = Color(red: 0.62, green: 0.48, blue: 0.95)
    static let trpgKP = Color(red: 0.48, green: 0.28, blue: 0.85)
    static let trpgOther = Color(red: 0.75, green: 0.68, blue: 0.92)

    static func trpg(_ role: String) -> Color {
        switch role {
        case "pl": return trpgPL
        case "kp": return trpgKP
        default: return trpgOther
        }
    }

    /// 重要度(0/1 参考・2 予定に影響・3 要対応)
    static func importance(_ i: Int) -> Color {
        switch i {
        case 3: return .red
        case 2: return .orange
        default: return .gray
        }
    }
}

extension View {
    /// カード(角丸の面)
    func todayCard(dim: Bool = false) -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TodayColors.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(dim ? 0.6 : 1)
    }
}

struct TodayBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: Capsule())
    }
}

/// 重要度バッジ(web 版 badge())
struct TodayImportanceBadge: View {
    let importance: Int?
    static let labels = ["参考", "参考", "予定に影響", "要対応"]

    var body: some View {
        if let i = importance, i >= 0, i < Self.labels.count {
            TodayBadge(text: Self.labels[i], color: TodayColors.importance(i))
        }
    }
}

/// TRPG の役割チップ(PL / KP / 他)
struct TodayTrpgChip: View {
    let role: String
    static let labels = ["pl": "PL", "kp": "KP", "other": "他"]

    var body: some View {
        if let l = Self.labels[role] {
            Text(l)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(.white)
                .background(TodayColors.trpg(role), in: Capsule())
        }
    }
}

/// 見出し(web 版 h2 + h2s)
struct TodaySectionHeader: View {
    let title: String
    var sub: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            if !sub.isEmpty { Text(sub).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

/// 一覧・別画面へのリンク行(web 版 linkCard())。NavigationLink や Link の中身に使う
struct TodayLinkRow: View {
    let icon: String
    let label: String
    var sub: String = ""
    var chevron: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Text(icon).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.body.weight(.semibold)).foregroundStyle(.primary)
                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }
        .todayCard()
        .contentShape(Rectangle())
    }
}

/// 空のときの一言
struct TodayEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }
}

/// 読み込み失敗の表示(再読み込みボタンつき)
struct TodayLoadError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("読み込めませんでした (\(message))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("再読み込み", action: retry).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// 画面下に数秒だけ出す一言(web 版 alertMsg())
struct TodayToast: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = text {
                Text(t)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if text == t { withAnimation { text = nil } }
                    }
            }
        }
        .animation(.default, value: text)
    }
}

extension View {
    func todayToast(_ text: Binding<String?>) -> some View { modifier(TodayToast(text: text)) }
}

/// 使い魔の返答・授業ノートの要約の簡易表示(web 版 richText(): 見出し・箇条書き・太字・コード・URL)
enum TodayRich {
    static func attributed(_ src: String) -> AttributedString {
        var lines: [String] = []
        var inCode = false
        for raw in src.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") {
            if raw.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { lines.append("`\(raw)`"); continue }
            var l = raw
            if let r = l.range(of: "^#{1,4} ", options: .regularExpression) {
                l = "**" + String(l[r.upperBound...]) + "**"
            } else if let r = l.range(of: "^\\s*[-*] ", options: .regularExpression) {
                let indent = l[l.startIndex..<r.lowerBound]
                l = String(indent) + "• " + String(l[r.upperBound...])
            }
            lines.append(l)
        }
        let md = lines.joined(separator: "\n")
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: md, options: opts)) ?? AttributedString(src)
    }
}
