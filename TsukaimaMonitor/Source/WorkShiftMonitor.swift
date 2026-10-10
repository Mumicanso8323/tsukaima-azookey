@preconcurrency import DeviceActivity
import Foundation

/// 区間の開始・終了を OS が知らせてくる。アプリが動いていなくても呼ばれる。
final class WorkShiftMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        WorkShiftBlockCore.applyShield()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        WorkShiftBlockCore.clearShield()
    }
}
