import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/// 「バイト中のブロック」の共有部分。アプリ本体と DeviceActivityMonitor 拡張の両方に入る。
/// 選んだアプリ(FamilyActivitySelection のトークン)は App Group の UserDefaults に JSON で置く。
/// トークンは端末内でしか意味を持たない不透明な値なので、サーバには送らない。
enum WorkShiftBlockCore {
    static let appGroup = "group.jp.yusukedoi.tsukaima.azookey"
    private static let selectionKey = "workShift.selection.v1"
    private static let plannedKey = "workShift.plannedDates.v1"

    /// 名前つきの ManagedSettingsStore。拡張とアプリで同じ名前を使えば同じ盾を操作できる
    nonisolated(unsafe) static let store = ManagedSettingsStore(named: .init("workShift"))

    static let testActivity = DeviceActivityName("workShift.test")
    static let dailyPrefix = "workShift.day."

    static func dailyActivity(dateKey: String) -> DeviceActivityName {
        DeviceActivityName(dailyPrefix + dateKey)
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func loadSelection() -> FamilyActivitySelection {
        guard let data = defaults?.data(forKey: selectionKey),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return FamilyActivitySelection() }
        return selection
    }

    static func saveSelection(_ selection: FamilyActivitySelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults?.set(data, forKey: selectionKey)
    }

    static func applyShield() {
        let selection = loadSelection()
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil : .specific(selection.categoryTokens)
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
    }

    static func clearShield() {
        store.clearAllSettings()
    }

    /// 非対応の長さを避けるための注意: DeviceActivitySchedule の区間は OS の制約で 15 分以上が要る
    static func startTestBlock(minutes: Int = 15) throws {
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(max(minutes, 15) * 60))
        let cal = Calendar.current
        let comps: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: cal.dateComponents(comps, from: now),
            intervalEnd: cal.dateComponents(comps, from: end),
            repeats: false
        )
        let center = DeviceActivityCenter()
        center.stopMonitoring([testActivity])
        // 区間の開始時に拡張の intervalDidStart が呼ばれて盾が立つが、
        // 開始が「今」だと呼ばれるまで間があるので、アプリからも先に立てておく
        applyShield()
        try center.startMonitoring(testActivity, during: schedule)
    }

    /// その日 06:00〜18:00 の盾を予約する(GL の日にサーバの予定を見て呼ぶ想定)。
    /// 同時に監視できる区間は OS 側で数が限られるので、直近 7 日ぶんほどだけを入れる
    static func scheduleShift(date: Date, startHour: Int = 6, endHour: Int = 18) throws {
        let cal = Calendar.current
        let day = cal.dateComponents([.year, .month, .day], from: date)
        var start = day; start.hour = startHour; start.minute = 0
        var end = day; end.hour = endHour; end.minute = 0
        let key = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false)
        try DeviceActivityCenter().startMonitoring(dailyActivity(dateKey: key), during: schedule)
    }

    static func cancelAllShifts() {
        let center = DeviceActivityCenter()
        center.stopMonitoring(center.activities.filter { $0.rawValue.hasPrefix(dailyPrefix) })
        clearShield()
    }
}
