import Foundation

/// ペアリングファイルの保管(Documents/Tsukaima/pairingFile.plist、
/// docs/tsukaima-springboard-icon-integration.md §4 の設計どおり)。
/// 中身は絶対にログ・画面に出さない(本人の既存方針)。NSFileProtectionComplete を付けて保存する
/// (端末バックアップにこのファイルが含まれる点への保険。同 §4)。
enum TsukaimaPairingFileStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tsukaima", isDirectory: true)
        return dir.appendingPathComponent("pairingFile.plist")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// UIDocumentPickerViewController(SwiftUI の fileImporter)が返す security-scoped URL から読み、
    /// 既存ファイルを atomic に置き換える。
    static func importFile(from source: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        try save(data)
    }

    static func save(_ data: Data) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let tmp = dir.appendingPathComponent(".pairingFile.tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: tmp.path)
        _ = try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tmp, to: fileURL)
    }

    static func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
