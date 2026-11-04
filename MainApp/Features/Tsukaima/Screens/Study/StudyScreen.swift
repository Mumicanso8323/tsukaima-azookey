import SwiftUI

/// 「勉強」タブ: 研究・復習・授業ノート(Web 版 tabs.study)
struct StudyScreen: View {
    var body: some View {
        NavigationStack {
            SLStudyHome()
                .navigationTitle("勉強")
                .navigationDestination(for: SLStudyRoute.self) { route in
                    switch route {
                    case .lectures: SLLectureListView()
                    case .lecture(let id): SLLectureDetailView(id: id)
                    case .survey: SLSurveyView()
                    }
                }
        }
    }
}

enum SLStudyRoute: Hashable {
    case lectures
    case lecture(String)
    case survey
}

private struct SLStudyHome: View {
    @State private var today: SLJSON?
    @State private var lectures: [SLJSON] = []
    @State private var surveyOpen = 0
    @State private var error: String?
    @State private var message: String?
    @State private var busy: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let d = today {
                    research(d["research"])
                    reviews(d["reviews"].array)
                    SLHeader(title: "授業ノート")
                    SLLectureRows(list: Array(lectures.prefix(4)))
                    NavigationLink(value: SLStudyRoute.lectures) {
                        SLLinkRow(icon: "📝", title: "授業ノートをすべて見る",
                                  sub: "\(lectures.count) 件\(lectures.count >= 100 ? "+" : "")")
                    }
                    .buttonStyle(.plain)
                    if surveyOpen > 0 {
                        NavigationLink(value: SLStudyRoute.survey) {
                            SLLinkRow(icon: "📮", title: "ひまな時アンケート 未回答 \(surveyOpen) 件", sub: "暇なときにでも")
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                } else {
                    SLLoadState(error: error) { Task { await load() } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await load() }
        .task { await load() }
        .slToast($message)
    }

    // 研究: 締切・次の一手(済で消す)・計画が古いとき
    @ViewBuilder private func research(_ rs: SLJSON) -> some View {
        SLHeader(title: "研究")
        let actions = rs["actions"].array, deadlines = rs["deadlines"].array
        if rs.truthy && (!actions.isEmpty || !deadlines.isEmpty || rs["stale"].truthy) {
            SLCard {
                ForEach(Array(deadlines.enumerated()), id: \.offset) { _, x in
                    let days = x["days"].int ?? 0
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SLDue(text: days != 0 ? "あと\(days)日" : "今日", hot: days <= 3)
                        Text(x["title"].text) + Text(x["confirmed"].truthy ? "" : "(推定)").font(.footnote).foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                if !actions.isEmpty {
                    SLSub("次の一手 \(actions.count) 件").padding(.top, 4)
                }
                ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                    let id = a["id"].text
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a["title"].text)
                            let meta = [a["due"].truthy ? "〜" + SLFmt.md(a["due"].string) : "",
                                        a["est_min"].truthy ? "約\(a["est_min"].text)分" : ""].filter { !$0.isEmpty }
                            HStack(spacing: 4) {
                                if !meta.isEmpty { SLSub(meta.joined(separator: " · ")) }
                                if let u = a["url"].string, let url = URL(string: u) {
                                    Link("資料", destination: url).font(.footnote)
                                }
                            }
                        }
                        Spacer()
                        Button("済") { Task { await researchDone(id) } }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(busy.contains("r" + id))
                    }
                }
                if rs["stale"].truthy {
                    SLSub("計画が古くなっています。研究セッションを開いて次の一手を更新").padding(.top, 4)
                }
            }
        } else {
            SLEmpty("研究の次の一手はありません")
        }
    }

    // 復習: 質問だけ出して、説明できたら「できた」
    @ViewBuilder private func reviews(_ list: [SLJSON]) -> some View {
        SLHeader(title: "復習", sub: list.isEmpty ? "" : "\(list.count) 件")
        if list.isEmpty {
            SLEmpty("今日の復習はありません")
        }
        ForEach(Array(list.enumerated()), id: \.offset) { _, r in
            let id = r["id"].text
            SLCard {
                HStack {
                    Text("📖 \(r["course"].text)").bold()
                    Spacer()
                    SLSub("\(SLFmt.md(r["recorded_at"].string)) · \(r["step"].truthy ? "2 回目" : "1 回目")")
                }
                ForEach(Array(r["questions"].array.enumerated()), id: \.offset) { _, q in
                    Text(q.text).padding(.vertical, 2)
                }
                HStack(spacing: 4) {
                    SLSub("答えは出しません。声に出すかメモに書いて説明できたら「できた」。")
                }
                NavigationLink("ノートを見る", value: SLStudyRoute.lecture(r["lecture_id"].text)).font(.footnote)
                HStack {
                    Button("できた") { Task { await review(id, ok: true) } }.buttonStyle(.borderedProminent)
                    Button("あやしい") { Task { await review(id, ok: false) } }.buttonStyle(.bordered)
                }
                .disabled(busy.contains("v" + id))
                .padding(.top, 4)
            }
        }
    }

    private func load() async {
        do {
            async let d = SLAPI.get("/api/today")
            async let l = SLAPI.get("/api/lectures")
            let (dd, ll) = try await (d, l)
            today = dd
            lectures = ll.array
            error = nil
        } catch {
            if today == nil { self.error = SLError.message(error) }
            else { message = SLError.message(error, fallback: "読み込めませんでした") }
        }
        if let sv = try? await SLAPI.get("/api/survey") { surveyOpen = sv["open"].array.count }
    }

    private func review(_ id: String, ok: Bool) async {
        busy.insert("v" + id)
        defer { busy.remove("v" + id) }
        do { try await SLAPI.post("/api/reviews/\(id)", ["ok": .b(ok)]) } catch { message = SLError.message(error) }
        await load()
    }

    private func researchDone(_ id: String) async {
        busy.insert("r" + id)
        defer { busy.remove("r" + id) }
        do { try await SLAPI.post("/api/research/\(SLAPI.escape(id))/done") } catch { message = SLError.message(error) }
        await load()
    }
}
