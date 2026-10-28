import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 会話モード(docs/converse-protocol.md 1章)向けの定数とエンドポイント。
enum ConverseConfig {
    static let sampleRate = 16000.0
    /// マイクから送るチャンクの長さ(0.2秒)。講義録音(1秒)より短くして、送信語の検出を速くする。
    static let chunkSamples = 3200
    static var wsURL: URL { TsukaimaEndpoint.webSocketURL("/ws/converse") }
}

/// アプリを一意に識別する id。合鍵登録済みならその端末 id、未登録なら identifierForVendor で代用。
enum ConverseDeviceID {
    static func current() -> String {
        if let id = UserDefaults.standard.string(forKey: "tsukaima.device.id"), !id.isEmpty { return id }
        #if canImport(UIKit)
        if let vendor = UIDevice.current.identifierForVendor?.uuidString { return vendor }
        #endif
        return "unknown"
    }
}
