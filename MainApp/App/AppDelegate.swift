import BackgroundTasks
import UIKit

/// 位置情報のバックグラウンド再起動と、写真自動バックアップの BGAppRefreshTask 登録を受けるための
/// 最小限の AppDelegate。
/// 大きな移動(significant location change)・訪問(visit)の監視中にアプリが終了していると、
/// iOS がここを呼んで裏で起こす(launchOptions[.location] の有無に関わらず、CLLocationManager の
/// delegate をここで必ず張り直す。張り直しが遅れると起こされた分のイベントを取りこぼすため、
/// didFinishLaunchingWithOptions を抜ける前に同期的に済ませる)。
/// BGTaskScheduler.register も同じ理由で、didFinishLaunchingWithOptions を抜ける前に必ず済ませる
/// (Apple のドキュメント通り。抜けた後に登録すると効かないことがある)。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TsukaimaLocationService.shared.applicationDidLaunchOrForeground()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: TsukaimaPhotoBackup.backgroundTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                TsukaimaPhotoBackup.shared.handleBackgroundRefresh(task: refreshTask)
            }
        }
        return true
    }
}
