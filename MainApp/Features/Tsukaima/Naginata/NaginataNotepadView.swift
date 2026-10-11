import AzooKeyUtils
import SwiftUI
import UIKit

/// 薙刀式のメモ帳。本文欄は薙刀式 ON の HardwareIME 入力欄(この画面の入力欄だけに効く)。
/// 配列図は常に表示。入力のたびに 0.5 秒デバウンスして Documents/naginata-notes/ に保存する。
struct NaginataNotepadView: View {
    @StateObject private var session = HardwareIMESession()
    @State private var text = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var copied = false
    @State private var currentId = 1
    @State private var showList = false
    @AppStorage(NaginataNoteStore.enabledKey) private var naginataOn = true
    @Environment(\.scenePhase) private var scenePhase
    private let store = NaginataNoteStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("入力方式", selection: $naginataOn) {
                    Text("薙刀式").tag(true)
                    Text("ふだんの入力").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("naginata.modePicker")

                HardwareIMECandidateBar(session: session)
                HardwareIMETextEditor(text: $text, placeholder: "ここに書く", minLines: 8, maxLines: 24,
                                      font: .preferredFont(forTextStyle: .title3),
                                      accessibilityID: "naginata.editor", session: session)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button("メモ一覧") {
                        saveNow()
                        showList = true
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("naginata.notes.list")
                    Button("新規") {
                        saveNow()
                        if let id = try? store.create() { switchTo(id, saveFirst: false) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("naginata.notes.new")
                    Button(copied ? "コピーしました" : "全文をコピー") {
                        commitPending()
                        UIPasteboard.general.string = text
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("naginata.copy")
                    Spacer()
                }

                NaginataLayoutFigure()
            }
            .padding()
        }
        .navigationTitle("薙刀式のメモ帳")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loaded {
                loaded = true
                currentId = store.index().current
                text = store.load(id: currentId)
            }
            session.core.naginata = naginataOn
        }
        .onChange(of: naginataOn) { _, on in
            session.core.naginata = on
        }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveNow() }
        }
        .onDisappear { saveNow() }
        .sheet(isPresented: $showList) {
            NaginataNoteListView(store: store, currentId: currentId) { id in
                showList = false
                switchTo(id, saveFirst: false)
            } onDeleted: { id in
                if id == currentId { switchTo(store.index().current, saveFirst: false) }
            }
        }
    }

    private func switchTo(_ id: Int, saveFirst: Bool) {
        if saveFirst { saveNow() }
        saveTask?.cancel()
        try? store.setCurrent(id)
        currentId = id
        text = store.load(id: id)
    }

    private func commitPending() {
        session.textView?.apply(session.core.commitAll())
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let id = currentId
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? store.save(text, id: id)
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        commitPending()
        guard loaded else { return }
        let id = currentId
        try? store.save(text, id: id)
        // binding の更新が一拍遅れても取りこぼさないよう、メインスレッドで更新後にもう一度保存する
        let snapshot = store
        Task { @MainActor in
            await Task.yield()
            if loaded, currentId == id { try? snapshot.save(text, id: id) }
        }
    }
}

/// 薙刀式の配列図(3 段 × 10 キー + 親指 Space)。各キーに単打のかな、右下に Space 同時のかなを小さく出す。
struct NaginataLayoutFigure: View {
    private static let rows = ["qwertyuiop", "asdfghjkl;", "zxcvbnm,./"]

    private static let single: [Character: String] = {
        var d: [Character: String] = [:]
        for e in NaginataTable.entries where e.keys.count == 1 {
            d[e.keys.first!] = e.output
        }
        return d
    }()

    private static let shifted: [Character: String] = {
        var d: [Character: String] = [:]
        for e in NaginataTable.entries where e.keys.count == 2 && e.keys.contains(" ") {
            if let k = e.keys.first(where: { $0 != " " }) { d[k] = e.output }
        }
        return d
    }()

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(Array(row), id: \.self) { k in
                        keyCap(k)
                    }
                }
            }
            Text("Space(親指): 単独は空白・変換 / 同時押しで下段の小さいかな")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("naginata.layout.thumb")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("naginata.layout")
    }

    private func keyCap(_ k: Character) -> some View {
        VStack(spacing: 0) {
            Text(Self.single[k] ?? " ")
                .font(.headline)
            Text(Self.shifted[k] ?? " ")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(k) \(Self.single[k] ?? "")")
        .accessibilityIdentifier("naginata.key.\(k)")
    }
}

/// メモの一覧(タップで切り替え、スワイプで削除)
struct NaginataNoteListView: View {
    let store: NaginataNoteStore
    let currentId: Int
    let onSelect: (Int) -> Void
    let onDeleted: (Int) -> Void
    @State private var ids: [Int] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(ids, id: \.self) { id in
                    Button {
                        onSelect(id)
                    } label: {
                        HStack {
                            Text(store.title(id: id)).font(.title3)
                            Spacer()
                            if id == currentId { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("naginata.notes.row.\(id)")
                }
                .onDelete { offsets in
                    let targets = offsets.map { ids[$0] }
                    for id in targets {
                        try? store.delete(id)
                        onDeleted(id)
                    }
                    ids = store.index().ids
                }
            }
            .navigationTitle("メモ一覧")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onAppear { ids = store.index().ids }
        }
    }
}
