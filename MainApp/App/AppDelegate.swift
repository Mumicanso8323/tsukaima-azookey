import UIKit

/// 位置情報のバックグラウンド再起動だけを受けるための最小限の AppDelegate。
/// 大きな移動(significant location change)・訪問(visit)の監視中にアプリが終了していると、
/// iOS がここを呼んで裏で起こす(launchOptions[.location] の有無に関わらず、CLLocationManager の
/// delegate をここで必ず張り直す。張り直しが遅れると起こされた分のイベントを取りこぼすため、
/// didFinishLaunchingWithOptions を抜ける前に同期的に済ませる)。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TsukaimaLocationService.shared.applicationDidLaunchOrForeground()
        return true
    }
}
