import Foundation

/// アプリのプロセスが(OS に殺されて、あるいはユーザーがスワイプで落として)再起動したとき、
/// 目覚まし state をどう復元すべきかを決める純ロジック。UIKit にも UserDefaults にも依存しないので
/// `swift test --package-path Logic` で検証できる。
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
