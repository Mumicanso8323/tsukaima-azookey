import CryptoKit
import Foundation
import LocalAuthentication

/// 端末の登録(ペアリング)・解除・端末署名・Face ID ステップアップ。
/// サーバ側: portal-bot bot/web.py(/api/devices/pair・/api/devices/native-key・/api/stepup/*・require_main_signature)。
/// 合鍵(トークン)はログ・画面・エラーメッセージに絶対に出さない。
enum TsukaimaDeviceAuth {
    enum AuthError: LocalizedError {
        case notPaired
        case cancelled
        case server(Int, String)
        case badResponse
        case badRequest
        /// pair は通って合鍵は保存済みだが、Face ID 用の鍵の登録(native-key)に失敗した
        case stepupKeyNotRegistered(String)
        /// Face ID 用の鍵が旧版(パスコードでも通る)か未登録。Tailscale 接続中に作り直しが要る
        case stepupKeyNeedsUpdate
        case needsTailscale

        var errorDescription: String? {
            switch self {
            case .notPaired: "この端末はまだ登録されていません"
            case .cancelled: "本人確認が取り消されました"
            case .server(let status, let detail): detail.isEmpty ? "hub からの応答が失敗しました (HTTP \(status))" : detail
            case .badResponse: "hub の応答を読み取れませんでした"
            case .badRequest: "署名できない要求です"
            case .stepupKeyNotRegistered(let why):
                "この端末の登録はできましたが、Face ID 用の鍵を hub に登録できませんでした(\(why))。Tailscale 接続中に 使い魔タブ → 端末 →「Face ID 用の鍵を登録し直す」を押してください"
            case .stepupKeyNeedsUpdate: "Face ID 用の鍵の更新が必要です。Tailscale 接続中に 使い魔タブ → 端末 →「鍵を更新」を押してください"
            case .needsTailscale: "Tailscale につながっていません。Tailscale 接続中に 使い魔タブ → 端末 →「鍵を更新」を押してください"
            }
        }
    }

    private static let deviceNameKey = "tsukaima.device.name"
    private static let deviceIDKey = "tsukaima.device.id"

    static var isPaired: Bool { TsukaimaDeviceToken.read() != nil }
    static var pairedName: String? { UserDefaults.standard.string(forKey: deviceNameKey) }

    /// Cookie を保存しない一時セッション(pair の応答は Set-Cookie で合鍵を返すので、共有の Cookie 置き場に残さない)
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    // MARK: 登録(Tailscale 接続中、または登録コードでどこからでも)

    /// 署名鍵を作って pair → 合鍵をすぐ Keychain に保存 → Face ID 用の鍵を native-key に登録。
    /// pairCode が nil なら従来どおり Tailscale 経由(自分自身を Tailscale で登録)。
    /// pairCode があれば api.yusukedoi.com 経由(別の登録済み端末で出した登録コードで、外から登録)。
    /// native-key だけ失敗した場合は合鍵を残し(サーバに端末を二重に作らない)、stepupKeyNotRegistered を投げる。
    /// その後は registerStepupKey() だけをやり直せばよい。
    static func pair(name: String, pairCode: String? = nil) async throws {
        guard TsukaimaDeviceKeys.biometryAvailable else { throw TsukaimaDeviceKeys.KeyError.biometryUnavailable }
        let signKey = try TsukaimaDeviceKeys.make(.sign)

        let url = pairCode == nil ? TsukaimaEndpoint.tailscaleURL("/api/devices/pair")
                                   : TsukaimaEndpoint.publicURL("/api/devices/pair")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "name": name,
            "sign_public_key": TsukaimaDeviceKeys.publicKeyB64(signKey),
        ]
        if let pairCode, !pairCode.isEmpty { body["pair_code"] = pairCode }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let pairJSON = try await jsonObject(req)
        guard let token = pairJSON["token"] as? String, !token.isEmpty else { throw AuthError.badResponse }

        try TsukaimaDeviceKeys.store(signKey, as: .sign)
        guard TsukaimaDeviceToken.save(token) else { throw TsukaimaDeviceKeys.KeyError.keychain }
        UserDefaults.standard.set((pairJSON["name"] as? String) ?? name, forKey: deviceNameKey)
        UserDefaults.standard.set(pairJSON["id"] as? String, forKey: deviceIDKey)
        TsukaimaDeviceKeys.delete(.stepup)
        TsukaimaDeviceKeys.setStepupVersion(0)

        do {
            // pairCode で外から登録した端末は Tailscale に届かないので、api.yusukedoi.com 側で
            // 「登録したばかり(15 分以内)・Face ID 鍵まだ無し」の一度きりの抜け道に乗る。
            try await registerStepupKey(viaPublicHost: pairCode != nil)
        } catch {
            throw AuthError.stepupKeyNotRegistered(error.localizedDescription)
        }
    }

    /// Face ID 用の鍵(生体認証のみ)を新しく作り、/api/devices/native-key に登録する。
    /// 通常(viaPublicHost: false)は Tailscale 経由(鍵の更新・作り直し)。
    /// pair() が外からの登録直後に呼ぶときだけ viaPublicHost: true で api.yusukedoi.com 経由にする
    /// (サーバ側が「登録直後 15 分・鍵まだ無し」の端末だけ、そこからの一度きりの登録を許す)。
    /// 登録が通ってから鍵を保存・版を更新するので、途中で失敗しても前の状態のまま(やり直せる)。
    static func registerStepupKey(viaPublicHost: Bool = false) async throws {
        guard let token = TsukaimaDeviceToken.read() else { throw AuthError.notPaired }
        let key = try TsukaimaDeviceKeys.make(.stepup)
        let url = viaPublicHost ? TsukaimaEndpoint.publicURL("/api/devices/native-key")
                                 : TsukaimaEndpoint.tailscaleURL("/api/devices/native-key")
        var nk = URLRequest(url: url)
        nk.httpMethod = "POST"
        nk.setValue("application/json", forHTTPHeaderField: "Content-Type")
        nk.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        nk.httpBody = try JSONSerialization.data(withJSONObject: ["public_key": TsukaimaDeviceKeys.publicKeyB64(key)])
        do {
            _ = try await jsonObject(nk)
        } catch is URLError {
            throw AuthError.needsTailscale
        } catch AuthError.server(403, _) {
            throw AuthError.needsTailscale
        }
        try TsukaimaDeviceKeys.store(key, as: .stepup)
        TsukaimaDeviceKeys.setStepupVersion(TsukaimaDeviceKeys.currentStepupVersion)
    }

    @MainActor private static var refreshing = false

    /// 前面に来たとき用: 登録済みで Face ID 用の鍵が旧版/未登録なら、黙って作り直しを試す
    /// (Tailscale 外なら失敗するだけ。その場合は端末画面とステップアップ時のエラーで案内する)。
    @MainActor
    static func refreshStepupKeyIfNeeded() {
        guard isPaired, TsukaimaDeviceKeys.stepupState != .ok, !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            try? await registerStepupKey()
        }
    }

    /// この端末から合鍵と鍵を消す(以後は Tailscale 経由に戻る)。サーバ側の取り消しは別途。
    static func unpair() {
        TsukaimaDeviceToken.delete()
        TsukaimaDeviceKeys.delete(.sign)
        TsukaimaDeviceKeys.delete(.stepup)
        TsukaimaDeviceKeys.setStepupVersion(nil)
        UserDefaults.standard.removeObject(forKey: deviceNameKey)
        UserDefaults.standard.removeObject(forKey: deviceIDKey)
    }

    // MARK: 端末署名(require_main_signature)

    /// 正規化文字列 METHOD\nPATH\nTS\nsha256hex(body) を自分で組み立てて署名し、付けるべきヘッダを返す。
    /// path はクエリ無しの "/api/..."(サーバの request.url.path と同じもの)。
    static func signatureHeaders(method: String, path: String, body: Data) throws -> [String: String] {
        let m = method.uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(m), path.hasPrefix("/api/"),
              !path.contains("?"), !path.contains("#"), !path.contains("\n") else { throw AuthError.badRequest }
        let bodyHex = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let ts = String(Int(Date().timeIntervalSince1970))
        let canonical = "\(m)\n\(path)\n\(ts)\n\(bodyHex)"
        let key = try TsukaimaDeviceKeys.load(.sign)
        let sig = try TsukaimaDeviceKeys.sign(key, Data(canonical.utf8))
        return ["X-Tsukaima-Ts": ts, "X-Tsukaima-Sig": sig]
    }

    // MARK: ステップアップ(毎回 Face ID)

    struct Elevation: Sendable {
        let token: String
        let expiresIn: Int
    }

    /// /api/stepup/challenge → Face ID で nonce に署名 → /api/stepup/native → 昇格トークン(5 分)
    static func stepUp(reason: String = "大事な操作の前に本人確認をします") async throws -> Elevation {
        guard let token = TsukaimaDeviceToken.read() else { throw AuthError.notPaired }
        // 旧版(パスコードでも通る .userPresence)や未登録の鍵ではステップアップしない
        guard TsukaimaDeviceKeys.stepupState == .ok else { throw AuthError.stepupKeyNeedsUpdate }
        guard TsukaimaDeviceKeys.biometryAvailable else { throw TsukaimaDeviceKeys.KeyError.biometryUnavailable }
        var ch = URLRequest(url: TsukaimaEndpoint.url("/api/stepup/challenge"))
        ch.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let chJSON = try await jsonObject(ch)
        guard let nonce = chJSON["nonce"] as? String, !nonce.isEmpty else { throw AuthError.badResponse }

        // Face ID の待ちで呼び出し元(メインスレッド)を塞がないよう、署名は別スレッドで。
        // 再利用猶予 0 の新しい LAContext を毎回作るので、直前に通っていても必ず Face ID が出る(鍵が .biometryAny なのでパスコード不可)。
        let signature: String = try await Task.detached(priority: .userInitiated) {
            let ctx = LAContext()
            ctx.touchIDAuthenticationAllowableReuseDuration = 0
            ctx.localizedReason = reason
            do {
                let key = try TsukaimaDeviceKeys.load(.stepup, context: ctx)
                return try TsukaimaDeviceKeys.sign(key, Data(nonce.utf8))
            } catch let e as TsukaimaDeviceKeys.KeyError {
                throw e
            } catch {
                throw AuthError.cancelled
            }
        }.value

        var nv = URLRequest(url: TsukaimaEndpoint.url("/api/stepup/native"))
        nv.httpMethod = "POST"
        nv.setValue("application/json", forHTTPHeaderField: "Content-Type")
        nv.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        nv.httpBody = try JSONSerialization.data(withJSONObject: ["nonce": nonce, "signature": signature])
        let res = try await jsonObject(nv)
        guard let el = res["elevation_token"] as? String, !el.isEmpty else { throw AuthError.badResponse }
        return Elevation(token: el, expiresIn: (res["expires_in"] as? NSNumber)?.intValue ?? 300)
    }

    // MARK: 補助

    private static func jsonObject(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard 200..<300 ~= status else { throw AuthError.server(status, TsukaimaAPI.detail(from: data)) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.badResponse }
        return obj
    }
}
