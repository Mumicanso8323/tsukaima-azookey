import AzooKeyUtils
import Foundation
import MetricKit

/// MetricKit(クラッシュ・ハング・CPU/ディスク例外)の診断ペイロードを hub へ送る。
/// 個人の入力内容は含まれない(OS がまとめて匿名化して生成するレポート)。
/// あわせて、キーボード拡張が App Group に溜めたパンくずと「今どのビルドが入っているか」も
/// 起動・前面化のたびに hub へ送る(Tailscale/LAN 抜きでリモートから追えるようにするための仕組み)。
@MainActor
final class TsukaimaDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = TsukaimaDiagnostics()

    /// サーバ側(/api/device/diagnostics)と揃えた上限。これを超えるペイロードは送らずに諦める。
    private static let maxPayloadBytes = 2 * 1024 * 1024
    private var started = false

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "?"
    }
    private static var keyboardBuild: String {
        SharedStore.userDefaults.string(forKey: TsukaimaKeyboardBreadcrumb.buildKey) ?? "?"
    }

    /// アプリ起動時に一度だけ呼ぶ(AppLaunchTasks.performMaintenance から)。
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        // pastDiagnosticPayloads は「この MXMetricManager インスタンスの初期化以降」しか返らないため
        // 起動直後はほぼ空だが、念のため拾っておく(iOS 14+。deprecated だが撤去はされていない)。
        let pending = MXMetricManager.shared.pastDiagnosticPayloads
        if !pending.isEmpty {
            upload(pending)
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Task { @MainActor in
            self.upload(payloads)
        }
    }

    private func upload(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            guard data.count <= Self.maxPayloadBytes else { continue }
            Task {
                guard let json = try? JSONSerialization.jsonObject(with: data) else { return }
                _ = try? await TsukaimaAPI.shared.sendJSON("POST", "/api/device/diagnostics", json: [
                    "app": "azooKey",
                    "app_build": "\(Self.appVersion)(\(Self.appBuild))",
                    "kb_build": Self.keyboardBuild,
                    "payload": json
                ])
            }
        }
    }

    /// 「今どのビルドが入っているか」を一行だけ送る(起動のたび)。
    func reportLaunch() async {
        let line = "launch app=\(Self.appVersion)(\(Self.appBuild)) kb=\(Self.keyboardBuild)"
        _ = try? await TsukaimaAPI.shared.sendJSON("POST", "/api/device/log", json: ["app": "azooKey", "lines": [line]])
    }

    /// キーボード拡張が溜めたパンくずを吸い出して送る。送信に成功したときだけ App Group 側を消す
    /// (キーボードはネットワークが無いことがある前提なので、消してから送るのは事故のもと)。
    func uploadKeyboardBreadcrumb() async {
        let lines = TsukaimaKeyboardBreadcrumb.peek()
        guard !lines.isEmpty else { return }
        let header = "build app=\(Self.appVersion)(\(Self.appBuild)) kb=\(Self.keyboardBuild)"
        do {
            _ = try await TsukaimaAPI.shared.sendJSON("POST", "/api/device/log", json: ["app": "keyboard", "lines": [header] + lines])
            TsukaimaKeyboardBreadcrumb.clear()
        } catch {
            // オフライン等。次の起動・前面化でまた試す(ファイルは残す)。
        }
    }
}
