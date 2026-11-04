import AzooKeyUtils
import Foundation

/// 使い魔のデータを TestFlight 版(bundle ID が変わり別アプリ扱い)へ運ぶ書き出し・読み込み。
/// 運ぶ物: UserDefaults.standard / App Group の UserDefaults(キー名で運ぶ)、App Group コンテナのファイル
/// (カスタムキー・テーマ・ユーザ辞書など)、薙刀式のメモと打鍵ログ。
/// 運ばない物: Keychain の合鍵・端末 ID・Face ID 用の鍵(再登録で作り直す)、ペアリングファイル(秘密)、
/// AlarmKit の登録と目覚ましの状態(起動時の ensure が置き直す)、キャッシュ・ログ・hub から取り直せる辞書。
enum TsukaimaTransfer {
    struct Environment {
        var standard: UserDefaults
        var standardDomain: String
        var group: UserDefaults
        var groupDomain: String
        var documents: URL
        var groupContainer: URL

        static var live: Environment {
            let groupDomain = SharedStore.appGroupKey
            return Environment(
                standard: .standard,
                standardDomain: Bundle.main.bundleIdentifier ?? "",
                group: UserDefaults(suiteName: groupDomain) ?? .standard,
                groupDomain: groupDomain,
                documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
                groupContainer: SharedStore.sharedContainerURL
            )
        }
    }

    enum Root: String { case documents, group }

    struct FileEntry: Equatable {
        var root: Root
        var path: String
        var data: Data
    }

    struct Payload {
        var exportedAt: Date
        var standard: [String: Any]
        var group: [String: Any]
        var files: [FileEntry]
        /// 入れなかった物(理由つき)
        var skipped: [Skip] = []

        var summary: Summary { Summary(defaultsCount: standard.count + group.count, fileCount: files.count, skipped: skipped) }
    }

    struct Skip: Equatable {
        enum Reason: String { case tooLarge = "大きすぎる", unreadable = "読めない", unsupportedValue = "保存できない形の値" }
        var path: String
        var reason: Reason
    }

    struct Summary: Equatable {
        var defaultsCount: Int
        var fileCount: Int
        var skipped: [Skip]
    }

    static let formatVersion = 1
    static let kind = "tsukaima-transfer"
    static let maxFileBytes = 16 * 1024 * 1024
    static let maxTotalBytes = 64 * 1024 * 1024

    // MARK: 運ぶ物の選び方

    private static let excludedKeyPrefixes = [
        "Apple", "NS", "AK", "com.apple.", "WebKit", "PayloadURLs",
        // 目覚ましの状態・控え(AlarmKit の登録は OS 側。起動時に置き直す)
        "alarm.",
        // 端末の登録(合鍵・Face ID 用の鍵は再登録で作り直す)
        "tsukaima.device.", "tsukaima.stepupKey",
        // hub から取り直す物の取得時刻
        "imeDict.lastFetch",
        // 本体の版の移行処理は新しい端末で普通に走らせる
        "LastAppVersion", "kb.lastSeenBuild",
    ]
    private static let secretWords = ["token", "secret", "password", "passwd", "pairing", "keychain", "apppassword"]

    static func shouldCarry(key: String) -> Bool {
        if excludedKeyPrefixes.contains(where: { key.hasPrefix($0) }) { return false }
        let lower = key.lowercased()
        return !secretWords.contains(where: { lower.contains($0) })
    }

    private static let documentsInclude = ["naginata-notes", "naginata-practice-log.jsonl"]
    private static let groupExcludeTop: Set<String> = ["library", "tmp", "systemdata"]
    /// どの深さにあっても運ばないファイル名(小文字で比較)。クリップボード履歴は登録コード・パスワードが残りうる
    private static let excludedFileNames: Set<String> = ["kb-breadcrumb.log", "hub-dict.json", "clipboard_history.json"]

    private static func isExcludedFile(_ path: String) -> Bool {
        excludedFileNames.contains((path as NSString).lastPathComponent.lowercased())
    }

    private static func carriedDefaults(_ defaults: UserDefaults, domain: String, dropped: inout [Skip]) -> [String: Any] {
        // dictionaryRepresentation() は OS・全体設定の値が混ざるので使わない(この領域だけを見る)
        let all = defaults.persistentDomain(forName: domain) ?? [:]
        var out: [String: Any] = [:]
        for (key, value) in all where shouldCarry(key: key) {
            if PropertyListSerialization.propertyList(value, isValidFor: .binary) { out[key] = value }
            else { dropped.append(Skip(path: "設定 \(key)", reason: .unsupportedValue)) }
        }
        return out
    }

    // MARK: 書き出し

    static func collect(_ env: Environment, now: Date = Date()) -> Payload {
        var skipped: [Skip] = []
        let standard = carriedDefaults(env.standard, domain: env.standardDomain, dropped: &skipped)
        let group = env.groupDomain == env.standardDomain ? [:] : carriedDefaults(env.group, domain: env.groupDomain, dropped: &skipped)
        var files: [FileEntry] = []
        var total = 0
        func add(root: Root, base: URL, topLevel: (String) -> Bool) {
            let fm = FileManager.default
            guard let tops = try? fm.contentsOfDirectory(atPath: base.path) else { return }
            for top in tops.sorted() where !top.hasPrefix(".") && topLevel(top) && !isExcludedFile(top) {
                let topURL = base.appendingPathComponent(top)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: topURL.path, isDirectory: &isDir) else { continue }
                var targets: [(String, URL)] = []
                if isDir.boolValue {
                    guard let en = fm.enumerator(at: topURL, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                    for case let u as URL in en {
                        guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                              !u.lastPathComponent.hasPrefix(".") else { continue }
                        let rel = String(u.path.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if !isExcludedFile(rel) { targets.append((rel, u)) }
                    }
                } else {
                    targets.append((top, topURL))
                }
                for (rel, url) in targets.sorted(by: { $0.0 < $1.0 }) {
                    guard let data = try? Data(contentsOf: url) else { skipped.append(Skip(path: rel, reason: .unreadable)); continue }
                    if data.count > maxFileBytes || total + data.count > maxTotalBytes { skipped.append(Skip(path: rel, reason: .tooLarge)); continue }
                    total += data.count
                    files.append(FileEntry(root: root, path: rel, data: data))
                }
            }
        }
        add(root: .documents, base: env.documents) { documentsInclude.contains($0) }
        add(root: .group, base: env.groupContainer) { !groupExcludeTop.contains($0.lowercased()) }
        return Payload(exportedAt: now, standard: standard, group: group, files: files, skipped: skipped)
    }

    static func plist(_ p: Payload) throws -> Data {
        let files: [[String: Any]] = p.files.map { ["root": $0.root.rawValue, "path": $0.path, "data": $0.data] }
        let dict: [String: Any] = [
            "kind": kind, "v": formatVersion, "exportedAt": p.exportedAt,
            "standard": p.standard, "group": p.group, "files": files,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    static func export(_ env: Environment = .live, passphrase: String,
                       iterations: Int = TsukaimaTransferFile.defaultIterations) throws -> (file: Data, summary: Summary) {
        guard TsukaimaTransferFile.trimmed(passphrase).count >= TsukaimaTransferFile.minPassphrase else {
            throw TsukaimaTransferFile.Failure.shortPassphrase
        }
        let payload = collect(env)
        // 設定が0件、または App Group が空(ファイルも設定も0)なら、読めていない可能性が高いので止める
        if payload.standard.count + payload.group.count == 0 || (payload.files.isEmpty && payload.group.isEmpty) {
            throw TsukaimaTransferFile.Failure.nothingToCarry
        }
        let file = try TsukaimaTransferFile.seal(plaintext: plist(payload), passphrase: passphrase, iterations: iterations)
        return (file, payload.summary)
    }

    // MARK: 読み込み

    static func parse(_ plaintext: Data) throws -> Payload {
        guard let obj = try? PropertyListSerialization.propertyList(from: plaintext, options: 0, format: nil),
              let d = obj as? [String: Any], d["kind"] as? String == kind, let v = d["v"] as? Int
        else { throw TsukaimaTransferFile.Failure.notTransferFile }
        guard v == formatVersion else { throw TsukaimaTransferFile.Failure.newerVersion }
        var files: [FileEntry] = []
        var total = 0
        for f in d["files"] as? [[String: Any]] ?? [] {
            guard let root = (f["root"] as? String).flatMap(Root.init(rawValue:)), let path = f["path"] as? String,
                  let data = f["data"] as? Data, isSafe(root: root, path: path) else { continue }
            total += data.count
            guard data.count <= maxFileBytes, total <= maxTotalBytes else { throw TsukaimaTransferFile.Failure.tooLarge }
            files.append(FileEntry(root: root, path: path, data: data))
        }
        return Payload(exportedAt: d["exportedAt"] as? Date ?? Date(timeIntervalSince1970: 0),
                       standard: (d["standard"] as? [String: Any] ?? [:]).filter { shouldCarry(key: $0.key) },
                       group: (d["group"] as? [String: Any] ?? [:]).filter { shouldCarry(key: $0.key) },
                       files: files)
    }

    /// 書き込み先の外に出る/対象外の相対パスは受け付けない
    static func isSafe(root: Root, path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { return false }
        switch root {
        case .documents: return documentsInclude.contains(parts[0]) && !isExcludedFile(path)
        case .group: return !groupExcludeTop.contains(parts[0].lowercased()) && !parts[0].hasPrefix(".") && !isExcludedFile(path)
        }
    }

    /// 中身の確認用(適用前に件数を見せる)。合言葉違い・壊れたファイルはここで落ちる。
    static func open(_ file: Data, passphrase: String) throws -> Payload {
        try parse(TsukaimaTransferFile.openPlaintext(file, passphrase: passphrase))
    }

    /// 既存の値・ファイルを上書きする(無い物は消さない)。書けなかったファイルがあっても最後まで進め、そのパスを返す
    @discardableResult
    static func apply(_ p: Payload, to env: Environment = .live) -> [String] {
        for (k, v) in p.standard { env.standard.set(v, forKey: k) }
        if env.groupDomain != env.standardDomain {
            for (k, v) in p.group { env.group.set(v, forKey: k) }
        }
        env.standard.synchronize()
        env.group.synchronize()
        let fm = FileManager.default
        var failed: [String] = []
        for f in p.files {
            let base = f.root == .documents ? env.documents : env.groupContainer
            let url = base.appendingPathComponent(f.path)
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.data.write(to: url, options: .atomic)
            } catch {
                failed.append(f.path)
            }
        }
        return failed
    }
}
