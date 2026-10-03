import Foundation

/// 端末の合鍵があれば api.yusukedoi.com(Tailscale 不要)、無ければ Tailscale 経由(TsukaimaEndpoint)。
/// 要求を組み立てるときは TsukaimaEndpoint.request(_:) を使うと api.yusukedoi.com 宛てにだけ Bearer が付く。
enum TsukaimaConfig {
    static var host: String { TsukaimaEndpoint.host }
    static var wsURL: URL { TsukaimaEndpoint.webSocketURL("/ws/record") }
    static var expiryURL: URL { TsukaimaEndpoint.url("/api/device/expiry") }
    static var wakeURL: URL { TsukaimaEndpoint.url("/api/wake") }
    static var logURL: URL { TsukaimaEndpoint.url("/api/device/log") }
    static let sampleRate = 16000.0
    static let chunk = 16000                // 1フレーム = 1秒
    static let maxBufferedChunks = 30 * 60  // 切断中に溜める上限 30分
}
