import Foundation

enum TsukaimaConfig {
    static let host = "ashwell-hub.taila653da.ts.net"   // Tailscale 経由でのみ到達
    static let wsURL = URL(string: "wss://\(host)/ws/record")!
    static let expiryURL = URL(string: "https://\(host)/api/device/expiry")!
    static let wakeURL = URL(string: "https://\(host)/api/wake")!
    static let logURL = URL(string: "https://\(host)/api/device/log")!
    static let sampleRate = 16000.0
    static let chunk = 16000                // 1フレーム = 1秒
    static let maxBufferedChunks = 30 * 60  // 切断中に溜める上限 30分
}
