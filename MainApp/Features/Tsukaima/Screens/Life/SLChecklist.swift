import SwiftUI

/// 帰る前のチェックリスト(Web 版は 設定 → ショートカット連携 の先頭)。外出オートメーションの通知と、
/// 朝 7:00 のまとめ通知(授業がある日)に出す持ち物。
struct SLChecklistView: View {
    @State private var items: [String] = []
    @State private var newItem = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var status = ""
    @State private var saving = false

    var body: some View {
        List {
            Section {
                if !loaded {
                    SLLoadState(error: error) { Task { await load() } }
                } else {
                    ForEach(items, id: \.self) { Text($0) }
                        .onDelete { items.remove(atOffsets: $0); Task { await save() } }
                        .onMove { items.move(fromOffsets: $0, toOffset: $1); Task { await save() } }
                    HStack {
                        TextField("持ち物を足す(例: 学生証)", text: $newItem)
                            .submitLabel(.done)
                            .onSubmit { add() }
                        Button("追加", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("「外出」オートメーションの通知と、朝 7:00 のまとめ通知(授業がある日)に使います。左にスワイプで削除、長押しで並べ替え。")
                    if !status.isEmpty { Text(status) }
                }
            }
        }
        .navigationTitle("帰る前のチェックリスト")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .refreshable { await load() }
        .task { await load() }
    }

    private func add() {
        // 読点・カンマ区切りでまとめて入れても分ける(Web 版の入力欄と同じ)
        let parts = newItem.split(whereSeparator: { $0 == "、" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        items += parts.filter { !items.contains($0) }
        newItem = ""
        Task { await save() }
    }

    private func load() async {
        do {
            items = try await SLAPI.get("/api/leave-checklist")["items"].array.map(\.text)
            loaded = true
            error = nil
        } catch {
            self.error = SLError.message(error)
        }
    }

    private func save() async {
        saving = true
        status = "保存中…"
        defer { saving = false }
        do {
            let r = try await SLAPI.post("/api/leave-checklist", ["items": .strings(items)])
            if r["items"].truthy { items = r["items"].array.map(\.text) }
            status = "✓ 保存しました"
        } catch {
            status = "保存できませんでした"
        }
    }
}
