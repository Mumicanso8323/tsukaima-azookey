import Foundation

/// hub の各エンドポイント。TsukaimaRecorder 本体・TsukaimaShare(共有拡張)の両方から使う
/// 共有ソース(project.yml の `Shared`)なので、本体の Sources/TsukaimaConfig.swift とは別に host を持つ。
enum TsukaimaHub {
    static let host = "ashwell-hub.taila653da.ts.net"   // Tailscale 経由でのみ到達

    static let intakeURL = URL(string: "https://\(host)/api/intake")!
    static let presenceURL = URL(string: "https://\(host)/api/presence")!
    static let applePayURL = URL(string: "https://\(host)/api/spend/applepay")!
    static let ocrURL = URL(string: "https://\(host)/api/spend/ocr")!
    static let healthURL = URL(string: "https://\(host)/api/health")!
}
