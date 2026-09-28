import SwiftUI
import QuickLook

// 授業ノート: 一覧(Web 版 tabs.lectures)・詳細(DETAIL.lecture)

private let SLLectureStatus: [String: String] = ["recording": "録音中", "summarizing": "要約中", "done": "", "error": "エラー"]

/// 授業ノートの行(Web 版 lectureRows)
struct SLLectureRows: View {
    let list: [SLJSON]

    var body: some View {
        if list.isEmpty {
            SLEmpty("まだありません")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, l in
                    NavigationLink(value: SLStudyRoute.lecture(l["id"].text)) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l["course"].text).foregroundStyle(.primary)
                                SLSub("\(SLFmt.md(l["recorded_at"].string)) \(SLFmt.hm(l["recorded_at"].string)) · \(SLFmt.grouped(l["chars"].double ?? 0)) 文字")
                            }
                            Spacer()
                            let st = l["status"].text
                            if let label = SLLectureStatus[st], !label.isEmpty {
                                SLBadge(text: label, color: st == "error" ? .red : .orange)
                            }
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < list.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
        }
    }
}

struct SLLectureListView: View {
    @Environment(\.openURL) private var openURL
    @State private var list: [SLJSON]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // 録音は「使い魔」タブのネイティブ録音へ(裏でも止まらない)
                Button {
                    openURL(URL(string: "tsukaima-rec://record")!)
                } label: {
                    Label("録音して文字起こし", systemImage: "record.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                if let list {
                    SLLectureRows(list: list)
                } else {
                    SLLoadState(error: error) { Task { await load() } }
                }
            }
            .padding(16)
        }
        .navigationTitle("授業ノート")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do { list = try await SLAPI.get("/api/lectures").array; error = nil }
        catch { self.error = SLError.message(error) }
    }
}

struct SLLectureDetailView: View {
    let id: String
    @State private var lec: SLJSON?
    @State private var error: String?
    @State private var asking = false
    @State private var fileURL: URL?
    @State private var opening: String?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let l = lec {
                    let st = SLLectureStatus[l["status"].text] ?? ""
                    SLSub("\(SLFmt.md(l["recorded_at"].string)) \(SLFmt.hm(l["recorded_at"].string))\(st.isEmpty ? "" : " · " + st)")
                    if let s = l["summary"].string, !s.isEmpty {
                        SLCard { SLRichText(source: s) }
                    }
                    Button { asking = true } label: {
                        Text("使い魔に聞く").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    let handouts = l["handouts"].array
                    if !handouts.isEmpty {
                        SLHeader(title: "配布資料")
                        VStack(spacing: 0) {
                            ForEach(Array(handouts.enumerated()), id: \.offset) { i, h in
                                Button { Task { await openHandout(h) } } label: {
                                    HStack(spacing: 8) {
                                        Text("📄")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(h["name"].text).foregroundStyle(.primary)
                                            SLSub("\(SLFmt.md(h["ts"].string)) \(SLFmt.hm(h["ts"].string))\(h["note"].truthy ? " · " + h["note"].text : "")")
                                        }
                                        Spacer()
                                        if opening == h["id"].text { ProgressView() }
                                        else { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                                    }
                                    .padding(10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if i < handouts.count - 1 { Divider() }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
                    }
                    SLHeader(title: "文字起こし\(l["cleaned"].truthy ? "(補正済み)" : "")")
                    SLCard {
                        let t = l["cleaned"].truthy ? l["cleaned"].text : l["transcript"].text
                        Text(t.isEmpty ? "(まだありません)" : t)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                } else {
                    SLLoadState(error: error) { Task { await load() } }
                }
            }
            .padding(16)
        }
        .navigationTitle(lec?["course"].string ?? "授業ノート")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $asking) { SLAskSheet(ref: "lecture:\(lec?["id"].text ?? id)") }
        .quickLookPreview($fileURL)
        .slToast($message)
    }

    private func load() async {
        do { lec = try await SLAPI.get("/api/lectures/\(SLAPI.escape(id))"); error = nil }
        catch { self.error = SLError.message(error) }
    }

    /// 配布資料は認証つきの GET なので、端末に落としてからクイックルックで開く
    private func openHandout(_ h: SLJSON) async {
        let hid = h["id"].text
        opening = hid
        defer { opening = nil }
        guard let (data, suggested) = await SLImageCache.shared.data("/api/intake/\(hid)/file") else {
            message = "開けませんでした"
            return
        }
        let name = (suggested?.isEmpty == false ? suggested! : h["name"].text).replacingOccurrences(of: "/", with: "_")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("handouts-\(hid)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.isEmpty ? "handout-\(hid)" : name)
        do {
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            message = "開けませんでした"
        }
    }
}

/// 返答・要約の簡易表示(Web 版 richText: コード・太字・見出し・箇条書き・URL だけ整形)
struct SLRichText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                if b.code {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(b.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
                } else {
                    Text(Self.inline(b.text)).textSelection(.enabled)
                }
            }
        }
    }

    private var blocks: [(code: Bool, text: String)] {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "```")
            .enumerated()
            .compactMap { i, p in
                if i % 2 == 1 {
                    var lines = p.components(separatedBy: "\n")
                    if let first = lines.first, first.range(of: #"^[\w+-]*$"#, options: .regularExpression) != nil { lines.removeFirst() }
                    return (true, lines.joined(separator: "\n").trimmingCharacters(in: .newlines))
                }
                let t = p.trimmingCharacters(in: .newlines)
                return t.isEmpty ? nil : (false, t)
            }
    }

    /// 見出し(#)は太字、- * は •、**太字**・`code`・URL はマークダウンとして解釈する
    static func inline(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            if let r = line.range(of: #"^#{1,4} "#, options: .regularExpression) {
                return "**" + String(line[r.upperBound...]) + "**"
            }
            if let r = line.range(of: #"^(\s*)[-*] "#, options: .regularExpression) {
                let indent = line[line.startIndex..<r.upperBound].prefix { $0 == " " || $0 == "\t" }
                return String(indent) + "• " + String(line[r.upperBound...])
            }
            return line
        }
        let md = lines.joined(separator: "\n")
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: md, options: opts)) ?? AttributedString(md)
    }
}
