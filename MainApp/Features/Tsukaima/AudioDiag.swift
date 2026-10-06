import AVFoundation
import UIKit

/// 音声セッション診断ログ(挙動は変えない)。`TsukaimaLog`(device_log)に `audio ...` 行を足すだけ。
/// 10 秒あたり最大 40 行まで。超えた分は捨てて、次の窓の最初に `audio ...suppressed N` を 1 行出す。
/// 10/6 の「イヤホンで A2DP → HFP → Speaker が 3 分に約 10 回」の原因切り分け用。
struct AudioDiagLimiter {
    enum Verdict: Equatable { case emit, emitAfterSuppressed(Int), drop }
    let maxLines: Int
    let window: Double
    private var windowStart = -Double.infinity
    private var count = 0
    private var suppressed = 0

    init(maxLines: Int = 40, window: Double = 10) {
        self.maxLines = maxLines
        self.window = window
    }

    mutating func admit(now: Double) -> Verdict {
        if now - windowStart >= window {
            let s = suppressed
            windowStart = now
            count = 1
            suppressed = 0
            return s > 0 ? .emitAfterSuppressed(s) : .emit
        }
        if count < maxLines {
            count += 1
            return .emit
        }
        suppressed += 1
        return .drop
    }
}

enum AudioDiag {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var limiter = AudioDiagLimiter()

    /// 1 行出す(どのスレッドからでも可)。device_log に `audio ...` として残る。
    static func log(_ line: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        switch limiter.admit(now: now) {
        case .drop:
            return
        case .emitAfterSuppressed(let n):
            TsukaimaLog.addAudio("audio ...suppressed \(n)")
        case .emit:
            break
        }
        TsukaimaLog.addAudio(line)
    }

    /// 前面/背景の状態を付けて 1 行出す(main に回して読む)。
    static func logWithApp(_ line: String) {
        DispatchQueue.main.async {
            let raw = MainActor.assumeIsolated { UIApplication.shared.applicationState.rawValue }
            let name = raw == 0 ? "active" : (raw == 1 ? "inactive" : "background")
            log("\(line) app=\(name)")
        }
    }

    // MARK: 文字列化

    static func short(_ raw: String) -> String {
        raw.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
            .replacingOccurrences(of: "AVAudioSessionMode", with: "")
    }

    static func ports(_ list: [AVAudioSessionPortDescription]) -> String {
        "[" + list.map { $0.portType.rawValue }.joined(separator: ",") + "]"
    }

    static func reasonName(_ raw: UInt) -> String {
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRoute"
        case .routeConfigurationChange: "routeConfigChange"
        default: "unknown"
        }
    }

    /// セッションの今の状態(category/mode/options/sampleRate)
    static func state(_ s: AVAudioSession) -> String {
        "cat=\(short(s.category.rawValue)) mode=\(short(s.mode.rawValue)) opts=\(s.categoryOptions.rawValue) sr=\(Int(s.sampleRate))"
    }

    /// 経路変更通知 1 件ぶんの詳細(既存の `route [...]` 行とは別に出す)
    static func logRouteChange(_ n: Notification, src: String) {
        let s = AVAudioSession.sharedInstance()
        let raw = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 999
        let prev = (n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
            .map { ports($0.outputs) } ?? "-"
        log("audio route src=\(src) reason=\(raw)(\(reasonName(raw))) prevOut=\(prev) in=\(ports(s.currentRoute.inputs)) out=\(ports(s.currentRoute.outputs)) \(state(s))")
    }

    // MARK: setCategory / setActive / override の薄いラッパー(同じ例外を投げ直す。呼び出し側の try / try? はそのまま)

    private static func logSet(_ src: String, _ s: AVAudioSession, active: String, err: Error?, extra: String = "") {
        let e = err.map { "\(($0 as NSError).domain)#\(($0 as NSError).code)" } ?? "-"
        log("audio set src=\(src) \(state(s)) active=\(active) err=\(e)\(extra)")
    }

    static func setCategory(_ src: String, _ s: AVAudioSession, _ category: AVAudioSession.Category,
                            mode: AVAudioSession.Mode = .default,
                            options: AVAudioSession.CategoryOptions = []) throws {
        do {
            try s.setCategory(category, mode: mode, options: options)
            logSet(src, s, active: "-", err: nil)
        } catch {
            logSet(src, s, active: "-", err: error)
            throw error
        }
    }

    static func setActive(_ src: String, _ s: AVAudioSession, _ active: Bool,
                          options: AVAudioSession.SetActiveOptions = []) throws {
        do {
            try s.setActive(active, options: options)
            logSet(src, s, active: active ? "1" : "0", err: nil)
        } catch {
            logSet(src, s, active: active ? "1" : "0", err: error)
            throw error
        }
    }

    static func override(_ src: String, _ s: AVAudioSession, _ port: AVAudioSession.PortOverride) throws {
        let name = port == .speaker ? "speaker" : "none"
        do {
            try s.overrideOutputAudioPort(port)
            logSet(src, s, active: "-", err: nil, extra: " override=\(name)")
        } catch {
            logSet(src, s, active: "-", err: error, extra: " override=\(name)")
            throw error
        }
    }
}
