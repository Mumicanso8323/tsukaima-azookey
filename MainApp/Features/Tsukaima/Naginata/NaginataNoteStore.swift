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
}
