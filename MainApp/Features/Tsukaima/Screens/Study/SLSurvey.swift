import SwiftUI

/// ひまな時アンケート(Web 版 survey)。低圧力: 締切・ストリーク・バッジ・通知は無し。答えるのは暇なときだけ。
struct SLSurveyView: View {
    @State private var open: [SLJSON] = []
    @State private var answered: [SLJSON] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var idx = 0
    @State private var chosen: [String] = []
    @State private var text = ""
    @State private var sending = false
    @State private var message: String?

    private var current: SLJSON? { open.indices.contains(idx) ? open[idx] : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !loaded {
                    SLLoadState(error: error) { Task { await load() } }
                } else {
                    if let q = current {
                        question(q)
                        if open.count > 1 {
                            Button("別の質問にする(\(idx + 1)/\(open.count))") {
                                idx = (idx + 1) % open.count
                                chosen = []
                                text = ""
                            }
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        SLEmpty("今はありません")
                    }
                    if !answered.isEmpty {
                        SLHeader(title: "答えたもの")
                        SLDisclosure("\(answered.count) 件") {
                            ForEach(Array(answered.enumerated()), id: \.offset) { _, r in
                                let a = r["answer"]
                                let parts = a["choices"].array.map(\.text) + (a["text"].truthy ? [a["text"].text] : [])
                                VStack(alignment: .leading, spacing: 2) {
                                    SLSub("\(r["topic"].text) · \(SLFmt.md(r["answered"].string))")
                                    Text(r["question"].text)
                                    if !parts.isEmpty { SLSub("→ " + parts.joined(separator: " / ")) }
                                }
                                .padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("ひまな時アンケート")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .slToast($message)
    }

    @ViewBuilder private func question(_ q: SLJSON) -> some View {
        let choices = q["choices"].array.map(\.text)
        SLCard {
            Text(q["topic"].text).font(.footnote.bold()).foregroundStyle(.secondary)
            Text(q["question"].text).font(.body)
            if q["why"].truthy { SLSub(q["why"].text) }
            if !choices.isEmpty {
                SLFlow(spacing: 6) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { _, c in
                        let on = chosen.contains(c)
                        Button {
                            if q["multi"].truthy {
                                if let i = chosen.firstIndex(of: c) { chosen.remove(at: i) } else { chosen.append(c) }
                            } else {
                                chosen = chosen.first == c ? [] : [c]
                            }
                        } label: {
                            Text(c).font(.subheadline)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(on ? Color.accentColor : Color(.tertiarySystemBackground)))
                                .foregroundStyle(on ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            if q["allow_text"].truthy {
                TextField("自由に書く(任意)", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
            }
            Button { Task { await send(q) } } label: {
                Text("送る").frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sending)
            .padding(.top, 4)
            Button("今はいい") { Task { await skip(q) } }
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        do {
            let d = try await SLAPI.get("/api/survey")
            open = d["open"].array
            answered = d["answered"].array
            if idx >= open.count { idx = 0 }
            chosen = []
            text = ""
            loaded = true
            error = nil
        } catch {
            self.error = SLError.message(error)
        }
    }

    private func send(_ q: SLJSON) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if chosen.isEmpty && t.isEmpty { message = "選ぶか書くかしてください"; return }
        sending = true
        defer { sending = false }
        do {
            // メインのセッションへの転記がある経路なので端末署名が要る
            try await SLAPI.post("/api/survey/\(SLAPI.escape(q["id"].text))/answer",
                                 ["choices": .strings(chosen), "text": .s(t)], signed: true)
        } catch {
            message = SLError.message(error, fallback: "送れませんでした")
            return
        }
        await load()
    }

    private func skip(_ q: SLJSON) async {
        do { try await SLAPI.post("/api/survey/\(SLAPI.escape(q["id"].text))/skip") }
        catch { message = SLError.message(error); return }
        await load()
    }
}

/// 折り返して並べる(選択肢のチップ・イヤホンの採点チップ)
struct SLFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
