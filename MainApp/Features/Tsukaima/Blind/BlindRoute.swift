import AVFoundation
import Foundation

/// 出力経路。private = イヤホン/Bluetooth/CarPlay、speaker = それ以外(内蔵スピーカーなど)。
enum BlindRoute: String, Equatable, Sendable {
    case privateOutput = "private"
    case speaker

    /// currentRoute.outputs のポート種別から決める(空・不明は speaker に倒す)。
    static func classify(outputs: [AVAudioSession.Port]) -> BlindRoute {
        let privatePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio,
        ]
        return outputs.contains(where: { privatePorts.contains($0) }) ? .privateOutput : .speaker
    }
}

/// 出力経路の読み取り元。テストと UI テストでは差し替える。
@MainActor
protocol BlindRouteSource: AnyObject {
    var current: BlindRoute { get }
    var onChange: ((BlindRoute) -> Void)? { get set }
}

/// AVAudioSession の currentRoute を読み、routeChange を見るだけ。setCategory / setActive は呼ばない(音声セッションに触れない)。
@MainActor
final class SystemBlindRouteSource: BlindRouteSource {
    var onChange: ((BlindRoute) -> Void)?
    private var observer: NSObjectProtocol?
    private var lastRoute: BlindRoute

    var current: BlindRoute { Self.read() }

    init() {
        lastRoute = Self.read()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let route = Self.read()
                guard route != self.lastRoute else { return }
                self.lastRoute = route
                self.onChange?(route)
            }
        }
    }

    private static func read() -> BlindRoute {
        BlindRoute.classify(outputs: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType))
    }
}

/// 固定の経路(UI テスト用)。
@MainActor
final class FixedBlindRouteSource: BlindRouteSource {
    var current: BlindRoute
    var onChange: ((BlindRoute) -> Void)?

    init(_ route: BlindRoute) {
        current = route
    }
}
