import SwiftUI

/// Claude 使用量(GET /api/claude-usage)。5 時間枠(session)と週(全体 / Fable)。
/// フィールドは個別に null になりうる。取得自体に失敗した場合はカードごと隠す(今日タブ本体は止めない)。
struct TodayClaudeUsage: Decodable, Sendable {
    struct Bucket: Decodable, Sendable {
        let usedPct: Int?
        let resets: String?

        enum CodingKeys: String, CodingKey {
            case usedPct = "used_pct"
            case resets
        }
    }

    let at: String?
    let session: Bucket?
    let weekAll: Bucket?
    let weekFable: Bucket?

    enum CodingKeys: String, CodingKey {
        case at, session
        case weekAll = "week_all"
        case weekFable = "week_fable"
    }

    @MainActor
    static func fetch() async -> TodayClaudeUsage? {
        try? await TsukaimaAPI.shared.get("/api/claude-usage")
    }
}

/// 今日タブ最上部の小さなカード。「Claude 残り: 5時間枠 N% 使用(リセット …)/ 週 N% 使用(リセット …)」
struct TodayClaudeUsageCard: View {
    let usage: TodayClaudeUsage

    private var rows: [TodayClaudeUsageRow] {
        [
            row(label: "5時間枠", bucket: usage.session),
            row(label: "週(全体)", bucket: usage.weekAll),
            row(label: "週(Fable)", bucket: usage.weekFable),
        ].compactMap { $0 }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude 残り").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in row }
                }
            }
            .todayCard()
        }
    }

    private func row(label: String, bucket: TodayClaudeUsage.Bucket?) -> TodayClaudeUsageRow? {
        guard let bucket, let pct = bucket.usedPct else { return nil }
        return TodayClaudeUsageRow(label: label, pct: pct, resets: bucket.resets ?? "")
    }
}

private struct TodayClaudeUsageRow: View {
    let label: String
    let pct: Int
    let resets: String

    private var clamped: Double { Double(min(max(pct, 0), 100)) }

    private var tint: Color {
        pct >= 90 ? TodayColors.hot : pct >= 70 ? TodayColors.warm : TodayColors.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(resets.isEmpty ? "\(pct)% 使用" : "\(pct)% 使用 (リセット \(resets))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: clamped, total: 100)
                .tint(tint)
        }
    }
}
