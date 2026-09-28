import SwiftUI

/// 「今日の授業」: 授業中/次の授業を大きく、残りを一覧で(web 版 tabs.today の授業部分)。
/// 授業中なら「授業終了」(2 回押しで確定)、連続コマで自動的に無しになったコマには「やっぱりある」。
struct TodayClassesSection: View {
    let data: TodayJSON
    let reload: @MainActor () async -> Void
    let toast: @MainActor (String) -> Void

    @State private var now = Date()

    var body: some View {
        // 「あと N 分」・終わった授業の薄表示を 1 分ごとに更新
        content(now: now)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    now = Date()
                }
            }
            .onChange(of: data) { _, _ in now = Date() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let classes = data["classes"].arr
        let cur = data["current"]
        let hasCur = cur.truthy
        let next: TodayJSON? = hasCur ? nil : classes.first { c in
            !c["skipped"].truthy && (TodayFmt.date(c["start"].s).map { $0 > now } ?? false)
        }
        let hero: TodayJSON? = hasCur ? cur : next
        let rest = classes.filter { c in hero.map { c["start"].s != $0["start"].s } ?? true }

        VStack(alignment: .leading, spacing: 8) {
            TodaySectionHeader(title: "今日の授業", sub: TodayFmt.mdToday(now))
            if let hero {
                let cls = classes.first { $0["start"].s == hero["start"].s } ?? hero
                heroCard(hero: hero, cls: cls, isCurrent: hasCur, now: now)
            }
            if !rest.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rest.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Divider() }
                        row(c, now: now)
                    }
                }
                .todayCard()
            } else if classes.isEmpty {
                TodayEmpty(text: "今日の授業はありません")
            }
        }
    }

    private func heroCard(hero: TodayJSON, cls: TodayJSON, isCurrent: Bool, now: Date) -> some View {
        let start = TodayFmt.date(hero["start"].s)
        let mins = start.map { Int(($0.timeIntervalSince(now) / 60).rounded()) } ?? 0
        var time = "\(TodayFmt.hm(hero["start"].s))〜\(TodayFmt.hm(hero["end"].s))"
        if !isCurrent && mins <= 180 { time += " · あと\(mins)分" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TodayBadge(text: isCurrent ? "授業中" : "次", color: isCurrent ? .orange : TodayColors.accent)
                Text(time).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(hero["title"].s).font(.title2.weight(.bold))
            if cls["location"].truthy {
                Text("📍 \(cls["location"].s)").font(.subheadline).foregroundStyle(.secondary)
            }
            if isCurrent, cls["id"].truthy {
                TodayEndClassButton(id: cls["id"].s, reload: reload, toast: toast)
                    .padding(.top, 4)
            }
        }
        .todayCard()
    }

    private func row(_ c: TodayJSON, now: Date) -> some View {
        let skipped = c["skipped"].truthy
        let ended = TodayFmt.date(c["end"].s).map { $0 < now } ?? false
        return HStack(alignment: .top, spacing: 10) {
            Text(TodayFmt.hm(c["start"].s))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(c["title"].s).font(.body.weight(.semibold))
                if c["location"].truthy {
                    Text("📍 \(c["location"].s)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if skipped {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("前のコマで終了 · 無し").font(.caption).foregroundStyle(.secondary)
                    TodayRestoreClassButton(id: c["id"].s, reload: reload, toast: toast)
                }
            } else {
                Text(c["ended_at"].truthy ? "\(TodayFmt.hm(c["ended_at"].s)) に終了" : "〜\(TodayFmt.hm(c["end"].s))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .opacity(skipped || ended ? 0.5 : 1)
    }
}

/// 「授業終了」: 誤タップ防止に、1 回目は「本当に終了」に変わるだけ(3 秒で戻る)。2 回目で記録する。
struct TodayEndClassButton: View {
    let id: String
    let reload: @MainActor () async -> Void
    let toast: @MainActor (String) -> Void
    @State private var armed = false
    @State private var busy = false
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Button {
            tap()
        } label: {
            Text(busy ? "終了処理中…" : armed ? "本当に終了" : "授業終了")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(armed ? .red : .secondary)
        .disabled(busy)
    }

    private func tap() {
        if !armed {
            armed = true
            disarm?.cancel()
            disarm = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled && !busy { armed = false }
            }
            return
        }
        disarm?.cancel()
        busy = true
        Task {
            do {
                _ = try await TodayAPI.send("POST", "/api/classes/\(TodayAPI.seg(id))/end")
                await reload()
            } catch {
                if !TodayAPI.isCancelled(error) { toast("授業終了の記録に失敗しました") }
            }
            busy = false
            armed = false
        }
    }
}

/// 「やっぱりある」: 連続コマで自動的に無し扱いになったコマを戻す(DELETE /api/classes/{id}/end)
struct TodayRestoreClassButton: View {
    let id: String
    let reload: @MainActor () async -> Void
    let toast: @MainActor (String) -> Void
    @State private var busy = false

    var body: some View {
        Button("やっぱりある") {
            busy = true
            Task {
                do {
                    _ = try await TodayAPI.send("DELETE", "/api/classes/\(TodayAPI.seg(id))/end")
                    await reload()
                } catch {
                    if !TodayAPI.isCancelled(error) { toast("戻せませんでした") }
                }
                busy = false
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(busy)
    }
}
