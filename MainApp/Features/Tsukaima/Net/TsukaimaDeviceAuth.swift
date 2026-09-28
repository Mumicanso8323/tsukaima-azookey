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

        var errorDescription: String? {
            switch self {
            case .notPaired: "この端末はまだ登録されていません"
            case .cancelled: "本人確認が取り消されました"
            case .server(let status, let detail): detail.isEmpty ? "hub からの応答が失敗しました (HTTP \(status))" : detail
            case .badResponse: "hub の応答を読み取れませんでした"
            case .badRequest: "署名できない要求です"
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

    // MARK: 登録(Tailscale 接続中に 1 回だけ)

    /// 鍵を 2 本作り、Tailscale 経由で pair → 同じ合鍵で native-key を登録 → Keychain に保存。
    /// 途中で失敗したら何も保存しない(サーバ側に残った未使用の端末は Web 版の端末一覧から取り消せる)。
    static func pair(name: String) async throws {
        let signKey = try TsukaimaDeviceKeys.create(.sign)
        let stepupKey = try TsukaimaDeviceKeys.create(.stepup)

        var req = URLRequest(url: TsukaimaEndpoint.tailscaleURL("/api/devices/pair"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "sign_public_key": TsukaimaDeviceKeys.publicKeyB64(signKey),
        ])
        let pairJSON = try await jsonObject(req)
        guard let token = pairJSON["token"] as? String, !token.isEmpty else { throw AuthError.badResponse }

        var nk = URLRequest(url: TsukaimaEndpoint.tailscaleURL("/api/devices/native-key"))
        nk.httpMethod = "POST"
        nk.setValue("application/json", forHTTPHeaderField: "Content-Type")
        nk.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        nk.httpBody = try JSONSerialization.data(withJSONObject: ["public_key": TsukaimaDeviceKeys.publicKeyB64(stepupKey)])
        _ = try await jsonObject(nk)

        guard TsukaimaDeviceToken.save(token) else { throw TsukaimaDeviceKeys.KeyError.keychain }
        UserDefaults.standard.set((pairJSON["name"] as? String) ?? name, forKey: deviceNameKey)
        UserDefaults.standard.set(pairJSON["id"] as? String, forKey: deviceIDKey)
    }

    /// この端末から合鍵と鍵を消す(以後は Tailscale 経由に戻る)。サーバ側の取り消しは別途。
    static func unpair() {
        TsukaimaDeviceToken.delete()
        TsukaimaDeviceKeys.delete(.sign)
        TsukaimaDeviceKeys.delete(.stepup)
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
        var ch = URLRequest(url: TsukaimaEndpoint.url("/api/stepup/challenge"))
        ch.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let chJSON = try await jsonObject(ch)
        guard let nonce = chJSON["nonce"] as? String, !nonce.isEmpty else { throw AuthError.badResponse }

        // Face ID の待ちで呼び出し元(メインスレッド)を塞がないよう、署名は別スレッドで。
        // 再利用猶予 0 の新しい LAContext を毎回作るので、直前に通っていても必ず本人確認が出る。
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
