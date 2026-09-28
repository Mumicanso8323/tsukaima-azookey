import SwiftUI

/// ひまな時アンケート(使い魔タブから開く)。低圧力: 締切・ストリーク・通知は無し。答えるのは暇なときだけ。
/// 回答はメインのセッションへの転記経路なので署名つき(signed: true)。「今はいい」は署名不要。
struct SurveyScreen: View {
    var onChange: () -> Void = {}

    @State private var open: [SurveyItem] = []
    @State private var answered: [SurveyItem] = []
    @State private var idx = 0
    @State private var chosen: [String] = []
    @State private var text = ""
    @State private var busy = false
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        List {
            if let q = current {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        if let topic = q.topic, !topic.isEmpty {
                            Text(topic).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(q.question ?? "").font(.headline)
                        if let why = q.why, !why.isEmpty {
                            Text(why).font(.footnote).foregroundStyle(.secondary)
                        }
                        let choices = q.choices ?? []
                        if !choices.isEmpty {
                            CSFlowLayout(spacing: 8) {
                                ForEach(choices, id: \.self) { c in
                                    let on = chosen.contains(c)
                                    Button(c) { toggle(c, multi: q.multi == true) }
                                        .font(.subheadline)
                                        .buttonStyle(.bordered)
                                        .buttonBorderShape(.capsule)
                                        .tint(on ? Color.accentColor : Color.secondary)
                                        .overlay { if on { Capsule().stroke(Color.accentColor, lineWidth: 1.5) } }
                                }
                            }
                        }
                        if q.allowText == true {
                            TextField("自由に書く(任意)", text: $text, axis: .vertical)
                                .lineLimit(2...6)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            Task { await send(q) }
                        } label: {
                            Text("送る").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                        HStack {
                            Button("今はいい") { Task { await skip(q) } }
                                .disabled(busy)
                            Spacer()
                            if open.count > 1 {
                                Button("別の質問にする(\(idx + 1)/\(open.count))") {
                                    idx = (idx + 1) % open.count
                                    chosen = []; text = ""
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if loaded {
                Section { Text("今はありません").foregroundStyle(.secondary) }
            }

            if !answered.isEmpty {
                Section {
                    DisclosureGroup("\(answered.count) 件") {
                        ForEach(answered) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(r.topic ?? "") · \(CSDate.md(r.answered))").font(.caption).foregroundStyle(.secondary)
                                Text(r.question ?? "")
                                let parts = (r.answer?.choices ?? []) + [(r.answer?.text ?? "")].filter { !$0.isEmpty }
                                if !parts.isEmpty {
                                    Text("→ " + parts.joined(separator: " / ")).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("答えたもの")
                }
            }
        }
        .navigationTitle("ひまな時アンケート")
        .navigationBarTitleDisplayMode(.inline)
        .tsukaimaTextSize()
        .task { await load() }
        .refreshable { await load() }
    }

    private var current: SurveyItem? { open.indices.contains(idx) ? open[idx] : nil }

    private func toggle(_ c: String, multi: Bool) {
        if multi {
            if let i = chosen.firstIndex(of: c) { chosen.remove(at: i) } else { chosen.append(c) }
        } else {
            chosen = chosen.first == c ? [] : [c]
        }
    }

    private func load() async {
        do {
            let d = try await CSNet.get("/api/survey", as: SurveyList.self)
            open = d.open
            answered = d.answered
            if idx >= open.count { idx = 0 }
            chosen = []; text = ""
            message = nil
        } catch {
            message = CSNet.message(error, fallback: "読み込めませんでした")
        }
        loaded = true
    }

    private func send(_ q: SurveyItem) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if chosen.isEmpty && body.isEmpty { message = "選ぶか書くかしてください"; return }
        busy = true
        defer { busy = false }
        do {
            try await CSNet.fire("POST", "/api/survey/\(CSNet.seg(q.id))/answer",
                                 json: ["choices": chosen, "text": body], signed: true)
        } catch {
            message = "送れませんでした: " + CSNet.message(error)
            return
        }
        await load()
        onChange()
    }

    private func skip(_ q: SurveyItem) async {
        busy = true
        defer { busy = false }
        do {
            try await CSNet.fire("POST", "/api/survey/\(CSNet.seg(q.id))/skip", json: [String: Any]())
        } catch {
            message = CSNet.message(error)
            return
        }
        await load()
        onChange()
    }
}
