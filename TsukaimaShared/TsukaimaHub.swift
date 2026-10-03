import Foundation

/// hub の各エンドポイント。本体(App Intents)・TsukaimaShare(共有拡張)の両方から使う共有ソース。
/// 端末の合鍵があれば api.yusukedoi.com、無ければ Tailscale(TsukaimaEndpoint が選ぶ)。
enum TsukaimaHub {
    static var host: String { TsukaimaEndpoint.host }

    static var intakeURL: URL { TsukaimaEndpoint.url("/api/intake") }
    static var presenceURL: URL { TsukaimaEndpoint.url("/api/presence") }
    static var healthURL: URL { TsukaimaEndpoint.url("/api/health") }
    static var locationURL: URL { TsukaimaEndpoint.url("/api/location") }
    // /api/spend/applepay・/api/spend/ocr は hub 側で「自動化トークン専用」(api.yusukedoi.com では端末の合鍵が
    // 効かない。bot/web.py AUTOMATION_ONLY_PATHS)。なので従来どおり Tailscale 経由に固定する。
    static var applePayURL: URL { TsukaimaEndpoint.tailscaleURL("/api/spend/applepay") }
    static var ocrURL: URL { TsukaimaEndpoint.tailscaleURL("/api/spend/ocr") }
}
