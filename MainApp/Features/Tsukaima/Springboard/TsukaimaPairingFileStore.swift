import Foundation

/// ペアリングファイルの保管(Documents/Tsukaima/pairingFile.plist、
/// docs/tsukaima-springboard-icon-integration.md §4 の設計どおり)。
/// 中身は絶対にログ・画面に出さない(本人の既存方針)。NSFileProtectionComplete を付けて保存する
/// (端末バックアップにこのファイルが含まれる点への保険。同 §4)。
///
/// 入手経路は 2 つ(同 §7.2):
/// - SideStore から: `sidestore://pairing?urlname=tsukaima-rec` を開くと SideStore が
///   `tsukaima-rec://pairingFile?data=<base64>` でこのアプリに返してくる(SideStore の
///   ExportPairingFileHandler、2026-09 以降の develop ビルド)。AppRouter が受けて `importBase64` を呼ぶ。
/// - ファイルから: PC の jitterbugpair 等で作った plist を「ファイル」経由で `.fileImporter` から取り込む。
enum TsukaimaPairingFileStore {
    /// 取り込み・削除のたびに投げる(画面側は onReceive で状態を読み直す)
    static let didChange = Notification.Name("TsukaimaPairingFileDidChange")

    /// SideStore に渡す自分の URL スキーム(Info.plist の CFBundleURLSchemes にある既存のもの)
    static let callbackScheme = "tsukaima-rec"
    /// SideStore 側の受け口。`urlname` に自分のスキームを渡すと `<scheme>://pairingFile?data=…` で返る
    static var sideStoreExportURL: URL? { URL(string: "sidestore://pairing?urlname=\(callbackScheme)") }

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

    /// SideStore のコールバック `tsukaima-rec://pairingFile?data=<base64>` を受ける。
    /// 該当 URL でなければ false(他の tsukaima-rec:// 用途と共存させるため)。
    /// base64 の中身はログにも画面にも出さない。
    @discardableResult
    static func importIfPairingCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == callbackScheme, url.host?.lowercased() == "pairingfile" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let b64 = query.first(where: { $0.name.lowercased() == "data" })?.value else { return false }
        return importBase64(b64)
    }

    @discardableResult
    static func importBase64(_ b64: String) -> Bool {
        // URL 経由で空白になった "+" を戻し、改行を捨ててからデコードする
        let cleaned = b64.replacingOccurrences(of: " ", with: "+").filter { !$0.isNewline }
        guard let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]), !data.isEmpty else { return false }
        guard looksLikePairingPlist(data) else { return false }
        do {
            try save(data)
            return true
        } catch {
            return false
        }
    }

    /// 最低限の形式確認(plist として読めて、ペアリング記録らしいキーがある)。値は読まない・出さない。
    static func looksLikePairingPlist(_ data: Data) -> Bool {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: .init(), format: nil),
              let dict = obj as? [String: Any] else { return false }
        return dict["HostID"] != nil || dict["HostCertificate"] != nil || dict["UDID"] != nil
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
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
