import Foundation

/// hub の各エンドポイント。本体(App Intents)・TsukaimaShare(共有拡張)の両方から使う共有ソース。
/// 端末の合鍵があれば api.yusukedoi.com、無ければ Tailscale(TsukaimaEndpoint が選ぶ)。
enum TsukaimaHub {
    static var host: String { TsukaimaEndpoint.host }

    static var intakeURL: URL { TsukaimaEndpoint.url("/api/intake") }
    static var presenceURL: URL { TsukaimaEndpoint.url("/api/presence") }
    static var healthURL: URL { TsukaimaEndpoint.url("/api/health") }
    static var locationURL: URL { TsukaimaEndpoint.url("/api/location") }
    // /api/spend/applepay・/api/spend/ocr は hub 側の「自動化トークン専用」経路だが、この 2 つだけは端末の合鍵(Bearer)でも
    // 通る(bot/web.py DEVICE_ALSO_PATHS・台帳 #1915)。合鍵があれば api.yusukedoi.com(TsukaimaNet が Bearer を載せる)、
    // 未登録なら従来どおり Tailscale。
    static var applePayURL: URL { TsukaimaEndpoint.url("/api/spend/applepay") }
    static var ocrURL: URL { TsukaimaEndpoint.url("/api/spend/ocr") }
}
