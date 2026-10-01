import Foundation

/// アプリのプロセスが(OS に殺されて、あるいはユーザーがスワイプで落として)再起動したとき、
/// 目覚まし state をどう復元すべきかを決める純ロジック。UIKit にも UserDefaults にも依存しないので
/// 単体テスト(azooKeyTests/TsukaimaAlarmLogicTests)で検証できる。
///
/// 実機バグの原因はここ: 旧コードは `fireAt` を過ぎていたら理由を問わず「見逃した」として
/// 黙って解除していた。そのため、鳴っている最中に通知をタップして(あるいは OS がバックグラウンド
/// 再生アプリを殺して)アプリを開き直すと、答え合わせを一切求められないまま目覚ましが止まって
/// しまっていた。「通知を開くと止まる」の正体はこの再起動パス。
///
/// 直したルール: 答えていない(`ringing`)/確認待ち(`checking`)の途中でプロセスが死んだ場合は、
/// 復元時刻に関わらず今すぐ鳴らし直す。時刻・締切が不明な壊れた状態も安全側(鳴らす)に倒す。
enum PersistedAlarmPhase: String, Sendable {
    case off, armed, ringing, checking
}

enum AlarmRestoreAction: Equatable, Sendable {
    /// 何もしない(元から off、あるいは fireAt を持たない壊れた armed 状態)
    case doNothing
    /// fireAt はまだ先。セットし直すだけの通常の armed 復元
    case rearm(fireAt: Date)
    /// 今すぐ鳴らす。答え合わせ無しで止まっていたバグの再発防止の要
    case ringNow
    /// 二度寝チェックの待機を、保存しておいた締切のまま再開する
    case resumeChecking(deadline: Date)
}

enum AlarmRestoreLogic {
    /// - Parameters:
    ///   - phase: 直前に永続化しておいた phase
    ///   - fireAt: 目覚まし時刻(armed/ringing/checking の間、保持され続ける値)
    ///   - checkDeadline: 二度寝チェック中の締切。`checking` のときだけ意味を持つ
    ///   - now: 現在時刻
    static func decide(phase: PersistedAlarmPhase, fireAt: Date?, checkDeadline: Date?, now: Date) -> AlarmRestoreAction {
        switch phase {
        case .off:
            return .doNothing
        case .armed:
            guard let fireAt else { return .doNothing }
            return fireAt > now ? .rearm(fireAt: fireAt) : .ringNow
        case .ringing:
            // まだ正解していない = 経過時間に関わらず今すぐ(鳴り直して)続ける
            return .ringNow
        case .checking:
            // 締切が読めない壊れた状態は安全側、つまり「鳴らす」に倒す
            guard let checkDeadline else { return .ringNow }
            return checkDeadline > now ? .resumeChecking(deadline: checkDeadline) : .ringNow
        }
    }
}

// MARK: - 前面化のたびの点検(プロセスが生きている間)

/// アプリが起動・前面化したとき(プロセスは生きていて、`restore()` は済んでいる)に何をすべきか。
/// 2026-10-01 の実機: アップデートで入れ直したあと、通知は来たのに本体も AlarmKit も鳴らなかった。
/// 無音再生の生存は OS 次第(更新・メモリ逼迫・クラッシュで黙って死ぬ)なので、前面に来るたびに
/// 「生きているか(無音再生・tick)」と「OS 側の AlarmKit 目覚ましが残っているか」を点検し直す。
enum AlarmForegroundAction: Equatable, Sendable {
    /// off、あるいは時刻を持たない壊れた armed。何もしない
    case doNothing
    /// まだ先。無音再生と tick を張り直し、AlarmKit の保険が `backupAt` に残っているか確かめる
    case keepAlive(backupAt: Date)
    /// 時刻・締切を過ぎているのにまだ鳴っていない(tick が止まっていた)。今すぐ鳴らす
    case ringNow
    /// 鳴っている最中。音声セッションを張り直すだけ(問題を作り直したりはしない)
    case resumeRinging
}

extension AlarmRestoreLogic {
    /// 二度寝チェックの保険は、本体が生きていれば締切ちょうどに鳴るので 1 分遅らせて置く
    /// (本番の目覚ましの保険は定刻ちょうど。理由は TsukaimaBackup のコメント)。
    static let checkBackupDelay: TimeInterval = 60

    /// - Parameters:
    ///   - phase: いまメモリ上にある phase(永続化した値ではない)
    ///   - fireAt / checkDeadline / now: `decide` と同じ
    static func foreground(phase: PersistedAlarmPhase, fireAt: Date?, checkDeadline: Date?, now: Date) -> AlarmForegroundAction {
        switch phase {
        case .off:
            return .doNothing
        case .armed:
            guard let fireAt else { return .doNothing }
            return fireAt > now ? .keepAlive(backupAt: fireAt) : .ringNow
        case .ringing:
            return .resumeRinging
        case .checking:
            guard let checkDeadline else { return .ringNow }
            return checkDeadline > now ? .keepAlive(backupAt: checkDeadline.addingTimeInterval(checkBackupDelay)) : .ringNow
        }
    }
}

// MARK: - AlarmKit の保険が OS に残っているかの判定

enum AlarmBackupVerdict: Equatable, Sendable {
    /// 期待どおりの時刻で OS に残っている
    case ok
    /// 置き直す。reason はログ用("missing" = OS から消えていた / "stale" = 時刻が違う / "none" = 置いた記録がない)
    case reschedule(reason: String)
}

enum AlarmBackupLogic {
    /// - Parameters:
    ///   - expected: いま保険が置かれているべき時刻
    ///   - storedID / storedAt: 前回 `schedule` が成功したときに控えた id と時刻
    ///   - scheduledIDs: OS(AlarmManager.alarms)にいま残っている、まだ鳴っていない目覚ましの id
    static func verify(expected: Date, storedID: UUID?, storedAt: Date?, scheduledIDs: Set<UUID>) -> AlarmBackupVerdict {
        guard let storedID, let storedAt else { return .reschedule(reason: "none") }
        guard abs(storedAt.timeIntervalSince(expected)) < 1 else { return .reschedule(reason: "stale") }
        return scheduledIDs.contains(storedID) ? .ok : .reschedule(reason: "missing")
    }
}

// MARK: - hub への状態報告(POST /api/alarm/state)

/// hub は寝る前の通知で「アラームがセットされていません」と注意するためにこれを見る。
/// 送るだけで何も待たない(目覚ましの動作をネットワークに依存させない)。
enum AlarmStateReport {
    static let apiPath = "/api/alarm/state"

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func payload(phase: PersistedAlarmPhase, fireAt: Date?, backupScheduled: Bool, backupID: UUID?, appBuild: String) -> [String: Any] {
        [
            "phase": phase.rawValue,
            "fireAt": fireAt.map { iso.string(from: $0) as Any } ?? NSNull(),
            "backupScheduled": backupScheduled,
            "backupId": backupID.map { $0.uuidString as Any } ?? NSNull(),
            "appBuild": appBuild,
        ]
    }
}
