import Foundation

/// 薙刀式メモ帳の保存先。Documents/naginata-notes/note-<id>.txt(本文のみ)。
/// 最初の版は note-1 の 1 枚だけ。複数メモにするときは id を増やす。
struct NaginataNoteStore {
    static let enabledKey = "naginata.enabled"

    let directory: URL

    init(directory: URL = NaginataNoteStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("naginata-notes", isDirectory: true)
    }

    func fileURL(id: Int = 1) -> URL {
        directory.appendingPathComponent("note-\(id).txt")
    }

    /// 無い・読めないときは空文字
    func load(id: Int = 1) -> String {
        guard let data = try? Data(contentsOf: fileURL(id: id)) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func save(_ text: String, id: Int = 1) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL(id: id), options: .atomic)
    }

    // MARK: - 複数メモ(index.json に並びと現在のメモを持つ。本文は note-<id>.txt)

    struct Index: Codable, Equatable {
        var ids: [Int]
        var current: Int
        var nextId: Int
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// 索引。無ければ(旧版の note-1.txt だけの状態を含め)1 枚目 = id 1 として組み立てる。
    func index() -> Index {
        if let data = try? Data(contentsOf: indexURL),
           var idx = try? JSONDecoder().decode(Index.self, from: data), !idx.ids.isEmpty {
            if !idx.ids.contains(idx.current) { idx.current = idx.ids[0] }
            idx.nextId = max(idx.nextId, (idx.ids.max() ?? 0) + 1)
            return idx
        }
        return Index(ids: [1], current: 1, nextId: 2)
    }

    private func writeIndex(_ idx: Index) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(idx).write(to: indexURL, options: .atomic)
    }

    func setCurrent(_ id: Int) throws {
        var idx = index()
        guard idx.ids.contains(id) else { return }
        idx.current = id
        try writeIndex(idx)
    }

    /// 新しい空のメモを作り、現在のメモにする
    @discardableResult
    func create() throws -> Int {
        var idx = index()
        let id = idx.nextId
        idx.ids.append(id)
        idx.nextId = id + 1
        idx.current = id
        try save("", id: id)
        try writeIndex(idx)
        return id
    }

    /// 削除。最後の 1 枚を消したときは空のメモを 1 枚残す。現在のメモを消したら先頭に移る。
    func delete(_ id: Int) throws {
        var idx = index()
        guard idx.ids.contains(id) else { return }
        idx.ids.removeAll { $0 == id }
        try? FileManager.default.removeItem(at: fileURL(id: id))
        if idx.ids.isEmpty {
            let fresh = idx.nextId
            idx.ids = [fresh]
            idx.nextId = fresh + 1
            try save("", id: fresh)
        }
        if !idx.ids.contains(idx.current) { idx.current = idx.ids[0] }
        try writeIndex(idx)
    }

    /// 一覧に出す題(本文の最初の空でない行。空なら「(空のメモ)」)
    func title(id: Int) -> String {
        let body = load(id: id)
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "(空のメモ)" : String(line.prefix(30))
    }
}
