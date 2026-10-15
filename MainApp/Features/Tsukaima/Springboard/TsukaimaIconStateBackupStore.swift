import Foundation

/// 適用前の配置(plist XML)を端末内に取っておく(Documents/Tsukaima/iconstate-backups/)。
/// 「元に戻す」は最新のバックアップをそのまま `set_icon_state` に流す。
/// 直近 `keepCount` 件だけ残す。中身はアプリ一覧(bundle id)なので秘密ではないが、
/// ペアリングファイルと同じディレクトリ規約(NSFileProtectionComplete)で保存する。
enum TsukaimaIconStateBackupStore {
    static let keepCount = 5

    struct Backup: Sendable, Identifiable, Equatable {
        var id: String { url.lastPathComponent }
        let url: URL
        let date: Date
    }

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tsukaima", isDirectory: true)
            .appendingPathComponent("iconstate-backups", isDirectory: true)
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func list() -> [Backup] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [Backup] = []
        for name in names where name.hasPrefix("iconstate-") && name.hasSuffix(".plist") {
            let stamp = String(name.dropFirst("iconstate-".count).dropLast(".plist".count))
            guard let date = nameFormatter.date(from: stamp) else { continue }
            out.append(Backup(url: directory.appendingPathComponent(name), date: date))
        }
        return out.sorted { $0.date > $1.date }
    }

    static var latest: Backup? { list().first }

    @discardableResult
    static func save(_ xml: Data, at date: Date = Date()) throws -> Backup {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let url = directory.appendingPathComponent("iconstate-\(nameFormatter.string(from: date)).plist")
        try xml.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        prune()
        return Backup(url: url, date: date)
    }

    static func load(_ backup: Backup) -> Data? {
        try? Data(contentsOf: backup.url)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func prune() {
        for old in list().dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }
}
