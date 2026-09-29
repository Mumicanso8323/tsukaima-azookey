import Foundation

/// 接続先の選び方。端末の合鍵(Keychain)があれば Cloudflare Tunnel の api.yusukedoi.com(Tailscale 不要)、
/// 無ければ従来の Tailscale ホスト。どちらも同じ FastAPI(portal-bot)につながる。
/// Bearer は URL のホストがちょうど api.yusukedoi.com(既定ポート)のときだけ付ける。
enum TsukaimaEndpoint {
    static let tailscaleHost = "ashwell-hub.taila653da.ts.net"
    static let publicHost = "api.yusukedoi.com"

    static var isPaired: Bool { TsukaimaDeviceToken.read() != nil }
    static var host: String { isPaired ? publicHost : tailscaleHost }

    /// path は "/api/..." の形(先頭スラッシュ付き)
    static func url(_ path: String) -> URL { URL(string: "https://\(host)\(path)")! }
    static func tailscaleURL(_ path: String) -> URL { URL(string: "https://\(tailscaleHost)\(path)")! }
    /// 常に api.yusukedoi.com(Cloudflare 経由)。合鍵をまだ持たない端末が登録コードで
    /// 外から登録するときなど、まだ isPaired が false でも公開ホストを明示したい場合に使う。
    static func publicURL(_ path: String) -> URL { URL(string: "https://\(publicHost)\(path)")! }
    static func webSocketURL(_ path: String) -> URL { URL(string: "wss://\(host)\(path)")! }

    static func isPublic(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "wss",
              url.host?.lowercased() == publicHost else { return false }
        return url.port == nil || url.port == 443
    }

    /// api.yusukedoi.com 宛てのときだけ合鍵を載せる(ts.net など他のホストには付けない)
    static func authorize(_ req: inout URLRequest) {
        guard isPublic(req.url), let token = TsukaimaDeviceToken.read() else { return }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        authorize(&req)
        return req
    }
}
