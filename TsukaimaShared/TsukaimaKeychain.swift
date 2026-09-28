import Foundation
import Security

/// 小さな Keychain ラッパー(kSecClassGenericPassword)。本体・共有拡張の両方から使う。
/// 値(端末の合鍵など)はログ・画面に一切出さないこと。
///
/// 共有アクセスグループ: 本体・キーボード・共有拡張が同じ App Group(com.apple.security.application-groups)を
/// 持つので、その App Group ID を kSecAttrAccessGroup に使う(Apple の仕様上、App Group は Keychain の
/// アクセスグループとして使える)。keychain-access-groups 権限は足さない — SideStore は再署名時にチーム ID を
/// 付けて ID を書き換えるため、固定値の keychain-access-groups は実 ID と合わなくなる。App Group なら
/// SideStore が実 ID を Info.plist の ALTAppGroups に書くので、実行時にそれを読めば正しいグループになる
/// (AzooKeyUtils/SharedStore.swift と同じ解決方法。キーボードの App Group 共有で実績あり)。
enum TsukaimaKeychain {
    private static let defaultAppGroup = "group.jp.yusukedoi.tsukaima.azookey"

    /// SideStore が書き換えた実際の App Group ID(無ければ既定値)。拡張は包んでいる本体の Info.plist も見る。
    static let sharedAccessGroup: String = {
        var groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
        if groups?.isEmpty ?? true, Bundle.main.bundleURL.pathExtension == "appex" {
            let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            groups = Bundle(url: appURL)?.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
        }
        let list = (groups ?? []).filter { !$0.isEmpty }
        return list.first { $0.hasPrefix(defaultAppGroup) } ?? list.first ?? defaultAppGroup
    }()

    /// accessGroup を指定しない読み出しは、自分が触れる全アクセスグループ(自分専用 + App Group)を探す
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
    /// 自分専用(既定)のアクセスグループに書く。sharedGroup: true なら App Group のアクセスグループにも同じ値を書く
    /// (共有拡張から読めるように)。App Group 側の書き込みに失敗しても(権限が無い署名など)本体は動く。
    @discardableResult
    static func set(_ data: Data, service: String, account: String, sharedGroup: Bool = false) -> Bool {
        delete(service: service, account: account)
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        let ok = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        if sharedGroup {
            q[kSecAttrAccessGroup as String] = sharedAccessGroup
            _ = SecItemAdd(q as CFDictionary, nil)
        }
        return ok
    }

    /// accessGroup を指定しない削除は、触れる全アクセスグループから消す
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
/// `Authorization: Bearer` で送る。本体の専用グループと App Group の共有グループの両方に置くので、共有拡張も
/// 読める(読めない署名のときは従来どおり Tailscale 経由になる)。App Group を持つキーボード拡張からも読める点に注意。
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
        TsukaimaKeychain.set(Data(token.utf8), service: service, account: account, sharedGroup: true)
    }

    static func delete() {
        TsukaimaKeychain.delete(service: service, account: account)
    }
}
