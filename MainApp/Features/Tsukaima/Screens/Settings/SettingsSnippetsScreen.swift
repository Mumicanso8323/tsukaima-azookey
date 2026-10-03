import SwiftUI
import UIKit

/// 設定 → 定型文。読み→本文の一覧(GET/PUT /api/ime/snippets)。保存すると使い魔キーの
/// ユーザー辞書(/api/ime/dict の words)にも乗り、キーボードの次のポーリングで候補に出る。
struct SettingsSnippetsScreen: View {
    @State private var items: [SettingsSnippet] = []
    @State private var loadError: String?
    @State private var newReading = ""
    @State private var newText = ""
    @State private var busy = false
    @State private var msg: String?

    var body: some View {
        Form {
            Section {
                if items.isEmpty && loadError == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.reading).font(.subheadline.bold())
                        Text(item.text).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    items.remove(atOffsets: offsets)
                    Task { await save() }
                }
            } header: {
                Text("定型文")
            } footer: {
                Text("読みを打つと本文が候補に出ます(例: 「がくせき」→「S0000000」)。左スワイプで削除。")
            }

            Section {
                TextField("読み(ひらがな)", text: $newReading)
                    .autocorrectionDisabled()
                TsukaimaComposerField(placeholder: "本文", text: $newText, maxLines: 4,
                                      textInset: UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
                Button(busy ? "保存中…" : "追加") { Task { await add() } }
                    .disabled(busy || newReading.trimmingCharacters(in: .whitespaces).isEmpty
                              || newText.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("追加")
            }

            if let msg {
                Section { Text(msg).font(.footnote).foregroundStyle(.secondary) }
            }
            if let loadError {
                Section { Text(loadError).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("定型文")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            items = try await CSNet.get("/api/ime/snippets", as: SettingsSnippetList.self).snippets
            loadError = nil
        } catch {
            loadError = "読み込めませんでした: " + CSNet.message(error)
        }
    }

    private func add() async {
        let reading = newReading.trimmingCharacters(in: .whitespaces)
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !reading.isEmpty, !text.isEmpty else { return }
        var next = items.filter { $0.reading != reading }
        next.append(SettingsSnippet(reading: reading, text: text))
        let before = items
        items = next
        newReading = ""
        newText = ""
        if !(await save()) {
            items = before
        }
    }

    @discardableResult
    private func save() async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let body: [String: Any] = ["snippets": items.map { ["reading": $0.reading, "text": $0.text] }]
            items = try await CSNet.send("PUT", "/api/ime/snippets", json: body, as: SettingsSnippetList.self).snippets
            msg = nil
            return true
        } catch {
            msg = "保存できませんでした: " + CSNet.message(error)
            return false
        }
    }
}
