import Foundation
#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

/// 保険の目覚まし。iOS 26 以降は AlarmKit(時計アプリと同じ扱い: 消音モード・集中モードでも鳴る)。
/// アプリ本体が OS に止められていても鳴る。本体の爆音より 1 分遅らせて置く。
enum TsukaimaBackup {
    private static let key = "alarm.backupID"

    static func schedule(_ date: Date) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            Task { await scheduleKit(date) }
        }
        #endif
    }

    static func cancel() {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let s = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: s) {
            try? AlarmManager.shared.cancel(id: id)
            UserDefaults.standard.removeObject(forKey: key)
            TsukaimaLog.add("backup cancel")
        }
        #endif
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    struct Meta: AlarmMetadata {}

    @available(iOS 26.0, *)
    private static func scheduleKit(_ date: Date) async {
        cancel()
        do {
            let m = AlarmManager.shared
            if m.authorizationState != .authorized {
                _ = try await m.requestAuthorization()
            }
            let alert = AlarmPresentation.Alert(
                title: "起きて！",
                stopButton: AlarmButton(text: "止める", textColor: .white, systemImageName: "stop.circle"))
            let attrs = AlarmAttributes<Meta>(presentation: AlarmPresentation(alert: alert), tintColor: .orange)
            let id = UUID()
            _ = try await m.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attrs, sound: .named("loud.wav")))
            UserDefaults.standard.set(id.uuidString, forKey: key)
            TsukaimaLog.add("backup set \(date.formatted(date: .omitted, time: .standard))")
        } catch {
            TsukaimaLog.add("backup error \(error)")
        }
    }
    #endif
}
