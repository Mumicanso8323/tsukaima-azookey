// ヘルスケア連携は既定で無効。
//
// 確認事実(2026-09、Apple Developer Forums): 無料の Personal Team は HealthKit capability を
// サポートしない("Your development team does not support the HealthKit capability")。
// このアプリは SideStore で無料 Apple ID による再署名を前提にしているため、HealthKit の
// entitlement をそのまま同梱すると再署名(≒インストール)自体が壊れる恐れがある。
//
// そのため既定のビルドでは HealthKit を一切リンクしない(このファイル一式は
// `#if HEALTHKIT` の中にあり、フラグを立てない限りコンパイル自体されない=Info.plist の
// 権限文言も HealthKit.framework の依存も不要)。有料の Apple Developer Program に移行できたら:
//   1. project.yml の TsukaimaRecorder に `dependencies: [{sdk: HealthKit.framework}]` を追加
//   2. entitlements(com.apple.developer.healthkit)と Info.plist に
//      NSHealthShareUsageDescription を追加
//   3. settings.base.SWIFT_ACTIVE_COMPILATION_CONDITIONS に "HEALTHKIT" を足す
// で有効化できる。
#if HEALTHKIT
import Foundation
import HealthKit

enum HealthBridge {
    static let store = HKHealthStore()

    private static var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = []
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { s.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .flightsClimbed) { s.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { s.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { s.insert(t) }
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(t) }
        return s
    }

    static func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw TsukaimaIntentError("この端末は Health に対応していません")
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// bot/health.py の POST /api/health が期待する形: {date, steps, flights, active_kcal, sleep_hours?, resting_hr?}
    static func snapshotForUpload() async -> [String: Any] {
        let now = Date()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        async let steps = sum(.stepCount, unit: .count(), from: startOfDay, to: now)
        async let flights = sum(.flightsClimbed, unit: .count(), from: startOfDay, to: now)
        async let kcal = sum(.activeEnergyBurned, unit: .kilocalorie(), from: startOfDay, to: now)
        async let hr = average(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()),
                                from: cal.date(byAdding: .day, value: -1, to: now) ?? now, to: now)
        async let sleepHours = lastNightSleepHours(now: now, cal: cal)

        var body: [String: Any] = ["date": dateString(now)]
        if let v = await steps { body["steps"] = Int(v) }
        if let v = await flights { body["flights"] = Int(v) }
        if let v = await kcal { body["active_kcal"] = Int(v) }
        if let v = await hr { body["resting_hr"] = Int(v) }
        if let v = await sleepHours { body["sleep_hours"] = v }
        return body
    }

    private static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    private static func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    private static func average(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stats, _ in
                cont.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    /// 前日正午〜今日正午の asleep 系サンプルを合算した時間(h)
    private static func lastNightSleepHours(now: Date, cal: Calendar) async -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let noonToday = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        guard let noonYesterday = cal.date(byAdding: .day, value: -1, to: noonToday) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: noonYesterday, end: noonToday, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let asleep: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                ]
                let secs = (samples as? [HKCategorySample] ?? [])
                    .filter { asleep.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                cont.resume(returning: secs > 0 ? secs / 3600 : nil)
            }
            store.execute(q)
        }
    }
}
#endif
