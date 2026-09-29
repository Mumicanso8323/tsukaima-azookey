import Foundation

// 設定画面で読む応答(bot/web.py)。値そのもの(パスワード・カード番号・トークン)は hub が返さない。
// デコードは CSNet(snake_case → camelCase)。

/// GET /api/devices の 1 件(last_ip などは表示しない)
struct SettingsDevice: Decodable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String?
    var revoked: Bool?
    var hasWebauthn: Bool?
    var hasNative: Bool?
}

struct SettingsDeviceList: Decodable, Sendable {
    var devices: [SettingsDevice]
}

/// GET /api/vault の 1 件: どの項目が入っているかだけ
struct SettingsVaultSite: Decodable, Sendable, Identifiable, Equatable {
    var site: String
    var login: Bool?
    var password: Bool?
    var totp: Bool?
    var id: String { site }
}

/// POST /api/vault → {ok, sites}
struct SettingsVaultSaved: Decodable, Sendable {
    var sites: [SettingsVaultSite]
}

/// GET /api/card → 下 4 桁と有効期限だけ(未登録は null)
struct SettingsCardInfo: Decodable, Sendable, Equatable {
    var last4: String?
    var exp: String?
}

struct SettingsAlarm: Decodable, Sendable {
    var enabled: Bool
}

struct SettingsTokenStatus: Decodable, Sendable {
    var issued: Bool
}

struct SettingsTokenIssued: Decodable, Sendable {
    var token: String
}

struct SettingsWhoami: Decodable, Sendable {
    var kind: String?
    var deviceName: String?
}

/// POST /api/devices/pair-code → 新しい端末を登録するための使い捨てコード
struct SettingsPairCodeIssued: Decodable, Sendable {
    var code: String
    var expiresIn: Int
}

struct SettingsChecklist: Decodable, Sendable {
    var items: [String]
}

/// GET /api/today のうち、設定画面で使う連携状態だけ
struct SettingsTodayLinks: Decodable, Sendable {
    struct Google: Decodable, Sendable {
        var configured: Bool?
        var accounts: [String]?
    }
    struct GAuth: Decodable, Sendable {
        var totp: Bool?
        var password: Bool?
    }
    var google: Google?
    var gauth: GAuth?
    var icloud: Bool?
}

/// POST /api/icloud → {calendars, events}
struct SettingsICloudResult: Decodable, Sendable {
    var calendars: [String]?
    var events: Int?
}

/// POST /api/gauth → {ok, code?} / GET /api/gauth/code → {code, left}
struct SettingsGAuthCode: Decodable, Sendable {
    var code: String?
    var left: Int?
}

/// GET/PUT /api/ime/snippets の 1 件。読み→本文をキーボードの候補として出す(bot/vocab.py ime_snippets_*)。
struct SettingsSnippet: Codable, Sendable, Identifiable, Equatable {
    var reading: String
    var text: String
    var id: String { reading }
}

struct SettingsSnippetList: Codable, Sendable {
    var snippets: [SettingsSnippet]
}
