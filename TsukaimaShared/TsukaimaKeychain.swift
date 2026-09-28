import Foundation
import Security

/// 小さな Keychain ラッパー(kSecClassGenericPassword)。本体・共有拡張の両方から使う。
/// 値(端末の合鍵など)はログ・画面に一切出さないこと。
enum TsukaimaKeychain {
    static func get(service: String, account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// 既存の項目を消してから書く。端末の外へは出ない(ThisDeviceOnly・iCloud キーチェーン非同期)。
    @discardableResult
    static func set(_ data: Data, service: String, account: String) -> Bool {
        delete(service: service, account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// hub の「端末の合鍵」(POST /api/devices/pair が一度だけ返す値)。api.yusukedoi.com へは
/// `Authorization: Bearer` で送る。共有拡張からは(Keychain のアクセスグループが違えば)見えないことがあり、
/// その場合は従来どおり Tailscale 経由になる。
enum TsukaimaDeviceToken {
    private static let service = "jp.yusukedoi.tsukaima.device-token"
    private static let account = "device_token"

    static func read() -> String? {
        guard let d = TsukaimaKeychain.get(service: service, account: account),
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        TsukaimaKeychain.set(Data(token.utf8), service: service, account: account)
    }

    static func delete() {
        TsukaimaKeychain.delete(service: service, account: account)
    }
}
