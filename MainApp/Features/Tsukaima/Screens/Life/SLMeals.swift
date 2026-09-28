import SwiftUI
import PhotosUI

// 食事: 大きい記録ボタン + 今日ぶんの一覧(タップで展開・編集・削除)。連続記録・目標は出さない(Web 版 mealsCard)

private let SLMealIcon: [String: String] = ["朝": "🌅", "昼": "☀️", "夜": "🌙", "間食": "🍪"]

struct SLMealsCard: View {
    let meals: [SLJSON]
    let changed: @MainActor () -> Void

    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    @State private var showText = false
    @State private var text = ""
    @State private var saving = false
    @State private var insightOpen = false
    @State private var insight: String?
    @State private var message: String?
    @FocusState private var textFocused: Bool

    var body: some View {
        SLHeader(title: "🍽 食事")
        SLCard {
            PhotosPicker(selection: $photo, matching: .images) {
                Label(uploading ? "送信中…" : "写真で記録", systemImage: "camera")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(uploading)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await upload(item) }
            }
            Button("写真なしで書く") {
                showText.toggle()
                if showText { textFocused = true }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            if showText {
                HStack {
                    TextField("例: 牛丼並、みそ汁", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($textFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await saveText() } }
                    Button("記録") { Task { await saveText() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving)
                }
            }
            if meals.isEmpty {
                SLEmpty("今日はまだ記録がありません")
            } else {
                ForEach(meals, id: \.self) { m in
                    SLMealRow(meal: m, changed: changed)
                    Divider()
                }
            }
            DisclosureGroup(isExpanded: $insightOpen) {
                Text(insight ?? "…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Text("週の傾向").font(.footnote).foregroundStyle(.secondary)
            }
            .tint(.secondary)
            .onChange(of: insightOpen) { _, open in
                if open && insight == nil { Task { await loadInsight() } }
            }
        }
        .slToast($message)
    }

    private func upload(_ item: PhotosPickerItem) async {
        uploading = true
        defer { uploading = false; photo = nil }
        guard let raw = try? await item.loadTransferable(type: Data.self) else {
            message = "写真を読み込めませんでした"
            return
        }
        let data = SLMealsCard.jpeg(raw) ?? raw
        do {
            _ = try await TsukaimaAPI.shared.upload("/api/meals", data: data, filename: "meal.jpg", mime: "image/jpeg", fields: [:])
        } catch {
            message = SLError.message(error, fallback: "記録できませんでした")
        }
        changed()
    }

    /// 写真は長辺 2048px の JPEG に縮める(サーバの上限 15MB・HEIC 対策)
    private static func jpeg(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return out.jpegData(compressionQuality: 0.85)
    }

    private func saveText() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            try await SLMealsCard.postText(t)
            text = ""
            showText = false
        } catch {
            message = SLError.message(error, fallback: "記録できませんでした")
        }
        changed()
    }

    /// 写真なしの記録(サーバはフォームの text を読む。空の写真欄は無視される)
    static func postText(_ t: String) async throws {
        _ = try await TsukaimaAPI.shared.upload("/api/meals", data: Data(), filename: "text.txt", mime: "text/plain", fields: ["text": t])
    }

    private func loadInsight() async {
        do {
            let r = try await SLAPI.get("/api/meals/insight", query: ["days": "14"])
            insight = r["text"].truthy ? r["text"].text : "まだ十分な記録がありません"
        } catch {
            insight = "取得できませんでした"
        }
    }
}

private struct SLMealRow: View {
    let meal: SLJSON
    let changed: @MainActor () -> Void

    @State private var open = false
    @State private var edit = ""
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var message: String?

    private var id: String { meal["id"].text }

    private var dish: String {
        let items = meal["items"].array
        if !items.isEmpty { return items.map { $0["name"].text }.joined(separator: "・") }
        if meal["text"].truthy { return meal["text"].text }
        return meal["photo"].truthy ? "(写真のみ)" : ""
    }

    private var kcal: String {
        switch meal["status"].text {
        case "pending": return "推定中…"
        case "error": return ""
        default: return meal["kcal_est"].isNull ? "" : "\(meal["kcal_est"].text) kcal 前後"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle(); if open { edit = meal["text"].text } } label: {
                HStack(spacing: 10) {
                    if meal["photo"].truthy {
                        SLRemoteImage(path: "/api/meals/\(id)/photo", size: 48)
                    } else {
                        Text(SLMealIcon[meal["kind"].text] ?? "🍽").font(.title2).frame(width: 48)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(meal["kind"].text).bold()
                            SLSub(SLFmt.hm(meal["ts"].string))
                        }
                        Text(dish.isEmpty ? "…" : dish).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(kcal).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                if meal["note"].truthy { SLSub(meal["note"].text) }
                if !meal["kcal_low"].isNull {
                    SLSub("目安 \(meal["kcal_low"].text)〜\(meal["kcal_high"].text) kcal(推定)")
                }
                HStack {
                    TextField("内容を書き直す", text: $edit).textFieldStyle(.roundedBorder)
                    Button("保存") { Task { await save() } }.buttonStyle(.bordered).disabled(busy)
                    Button("削除", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered).disabled(busy)
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("この記録を削除しますか", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await delete() } }
        }
        .slToast($message)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do { try await SLAPI.post("/api/meals/\(id)", ["text": .s(edit)]) }
        catch { message = SLError.message(error, fallback: "保存できませんでした") }
        changed()
    }

    private func delete() async {
        busy = true
        defer { busy = false }
        do { try await SLAPI.delete("/api/meals/\(id)") }
        catch { message = SLError.message(error, fallback: "削除できませんでした") }
        changed()
    }
}
