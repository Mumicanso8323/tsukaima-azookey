import Foundation
#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

/// 保険の目覚まし。iOS 26 以降は AlarmKit(時計アプリと同じ扱い: 消音モード・集中モードでも鳴る)。
/// アプリ本体が OS に止められていても鳴る。
///
/// 2026-10-01 の実機では、寝る前に置いた保険(ログ `backup set 9:11:00`)が朝には OS から消えていて
/// 鳴らなかった(SideStore でアプリを入れ直した日。入れ直しで AlarmKit の登録が落ちた疑いが濃い)。
/// 以来の方針:
/// - 本番の目覚まし(armed)の保険は **定刻ちょうど** に置く。本体の爆音は「生きていれば」鳴る側で、
///   AlarmKit は本体が死んでいても鳴る唯一の層なので、1 分遅らせて起床を遅らせる理由がない。
///   両方鳴っても、AlarmKit の「止める」は本体の鳴りには一切触れない(止めるのは `answer(_:)` だけ)。
/// - 二度寝チェックの保険だけは締切 +1 分(`AlarmRestoreLogic.checkBackupDelay`)。本体が生きていれば
///   締切ちょうどに鳴るので、そこで答えれば OS の目覚ましまで鳴らさずに済む。
/// - 置いたきりにせず、起動・前面化のたびに `ensure(at:)` で OS に残っているか確かめ、無ければ置き直す。
/// - OS 側の操作(schedule / cancel / ensure)は 1 本の直列キューで順番に流す。並べて走らせると
///   「置き直し」どうしが競合して、控えの id を持たない孤児の目覚ましが残る(= 答えた後にも鳴る)。
/// - 音は `.default`。以前の `.named("loud.wav")` はバンドルに無いファイルを指していた。
enum TsukaimaBackup {
    private static let key = "alarm.backupID"
    private static let atKey = "alarm.backupAt"

    /// 前回 schedule が成功したときに控えた id(hub への状態報告用)
    static var storedID: UUID? {
        UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    /// `date` に保険を置く。完了時に成否を main で返す(待たなくてよい呼び出し側は completion を省く)。
    static func schedule(_ date: Date, completion: (@MainActor (Bool) -> Void)? = nil) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            enqueue {
                let ok = await scheduleKit(date)
                completion?(ok)
            }
            return
        }
        #endif
        Task { @MainActor in completion?(false) }
    }

    static func cancel() {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            enqueue { await cancelKit() }
        }
        #endif
    }

    /// 起動・前面化のたびに呼ぶ。`date` の保険が OS に残っていれば何もせず、消えていた・時刻が違う・
    /// 置いた記録が無いなら置き直す。completion には「いま OS に保険がある」かを main で返す。
    static func ensure(at date: Date, completion: @escaping @MainActor (Bool) -> Void) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            enqueue {
                let ok = await ensureKit(date)
                completion(ok)
            }
            return
        }
        #endif
        Task { @MainActor in completion(false) }
    }

    // MARK: - 直列キュー

    @MainActor private static var queue: Task<Void, Never>?

    private static func enqueue(_ op: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            let prev = queue
            queue = Task { @MainActor in
                await prev?.value
                await op()
            }
        }
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    struct Meta: AlarmMetadata {}

    /// OS に残っている、まだ鳴っていないこのアプリの目覚ましの id
    @available(iOS 26.0, *)
    @MainActor private static func scheduledIDs() -> Set<UUID> {
        let all = (try? AlarmManager.shared.alarms) ?? []
        return Set(all.filter { $0.state == .scheduled }.map(\.id))
    }

    @available(iOS 26.0, *)
    @MainActor private static func cancelKit() async {
        let m = AlarmManager.shared
        // このアプリの AlarmKit 目覚ましは保険の 1 本だけなので、控えの id に限らず全部消す(孤児を残さない)
        for a in (try? m.alarms) ?? [] {
            try? m.cancel(id: a.id)
        }
        if UserDefaults.standard.string(forKey: key) != nil {
            TsukaimaLog.add("backup cancel")
        }
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: atKey)
    }

    @available(iOS 26.0, *)
    @MainActor private static func scheduleKit(_ date: Date) async -> Bool {
        await cancelKit()
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
            _ = try await m.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attrs, sound: .default))
            UserDefaults.standard.set(id.uuidString, forKey: key)
            UserDefaults.standard.set(date, forKey: atKey)
            TsukaimaLog.add("backup set \(date.formatted(date: .omitted, time: .standard))")
            return true
        } catch {
            TsukaimaLog.add("backup error \(error)")
            return false
        }
    }

    @available(iOS 26.0, *)
    @MainActor private static func ensureKit(_ date: Date) async -> Bool {
        let verdict = AlarmBackupLogic.verify(
            expected: date, storedID: storedID,
            storedAt: UserDefaults.standard.object(forKey: atKey) as? Date,
            scheduledIDs: scheduledIDs())
        switch verdict {
        case .ok:
            TsukaimaLog.add("backup verify ok")
            return true
        case .reschedule(let reason):
            let ok = await scheduleKit(date)
            TsukaimaLog.add("backup \(reason) -> \(ok ? "rescheduled" : "reschedule failed")")
            return ok
        }
    }
    #endif
}
