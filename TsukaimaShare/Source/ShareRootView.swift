import SwiftUI
import UniformTypeIdentifiers

/// 共有シートから来たファイル/画像/PDF(複数可)を1件ずつ /api/intake へ送る。
/// 「ルルブとして送る」をオンにすると note=rulebook:<system/book> を添えて通常の仕分けを飛ばす。
struct ShareRootView: View {
    let items: [NSItemProvider]
    weak var context: NSExtensionContext?

    private static let defaultRulebook = "nechronica/基本ルールブック"
    private static let rulebookKey = "share.isRulebook"
    private static let noteKey = "share.rulebookNote"

    @State private var isRulebook = UserDefaults.standard.bool(forKey: ShareRootView.rulebookKey)
    @State private var rulebookNote = UserDefaults.standard.string(forKey: ShareRootView.noteKey) ?? ShareRootView.defaultRulebook
    @State private var sending = false
    @State private var results: [String] = []
    @State private var done = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(items.isEmpty ? "送るファイルがありません" : "\(items.count) 件を使い魔に送ります")
                        .font(.subheadline)
                }
                Section {
                    Toggle("ルルブとして送る", isOn: $isRulebook)
                    if isRulebook {
                        TextField("system/book", text: $rulebookNote)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("例: nechronica/基本ルールブック。自分用の TRPG ルールブックを保存・OCR します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !results.isEmpty {
                    Section("結果") {
                        ForEach(results, id: \.self) { Text($0) }
                    }
                }
            }
            .navigationTitle("使い魔に送る")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        context?.cancelRequest(withError: NSError(domain: "jp.yusukedoi.tsukaima.share", code: 1))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else if done {
                        Button("閉じる") { context?.completeRequest(returningItems: nil) }
                    } else {
                        Button("送信") { send() }.disabled(items.isEmpty)
                    }
                }
            }
        }
    }

    private func send() {
        UserDefaults.standard.set(isRulebook, forKey: Self.rulebookKey)
        UserDefaults.standard.set(rulebookNote, forKey: Self.noteKey)
        sending = true
        let note: String?
        if isRulebook {
            let v = rulebookNote.trimmingCharacters(in: .whitespacesAndNewlines)
            note = "rulebook:\(v.isEmpty ? Self.defaultRulebook : v)"
        } else {
            note = nil
        }
        let capturedItems = items
        Task {
            var out: [String] = []
            for provider in capturedItems {
                do {
                    let (data, filename, mime) = try await Self.load(provider)
                    var fields: [String: String] = [:]
                    if let note { fields["note"] = note }
                    let json = try await TsukaimaNet.postMultipart(TsukaimaHub.intakeURL, fields: fields, fileField: "file",
                                                            filename: filename, mime: mime, data: data)
                    out.append((json["summary"] as? String) ?? "送信しました")
                } catch {
                    out.append("失敗: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                results = out
                sending = false
                done = true
            }
        }
    }

    /// NSItemProvider からファイルを読み出す。loadFileRepresentation の completion が返ると
    /// 一時ファイルは消えるので、その前に Data として読み切る。
    private static func load(_ provider: NSItemProvider) async throws -> (Data, String, String) {
        let typeId = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        return try await withCheckedThrowingContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let url else {
                    cont.resume(throwing: NSError(domain: "jp.yusukedoi.tsukaima.share", code: 2,
                                                   userInfo: [NSLocalizedDescriptionKey: "ファイルを読み込めませんでした"]))
                    return
                }
                do {
                    let data = try Data(contentsOf: url)
                    let mime = UTType(typeId)?.preferredMIMEType ?? "application/octet-stream"
                    cont.resume(returning: (data, url.lastPathComponent, mime))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
