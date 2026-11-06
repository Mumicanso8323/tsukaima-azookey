import AppIntents
import Foundation

/// 時間割(hub の bot.db)に従う自動操作の App Intent。どちらもショートカットの個人オートメーション
/// (「実行前に確認しない」)から呼ぶ前提で、画面は出さない(openAppWhenRun = false)。
enum TsukaimaAutoSchedules {
    static func fetch() async throws -> TsukaimaAutoSchedule {
        let data = try await TsukaimaNet.getData(TsukaimaHub.autoScheduleURL)
        guard let s = TsukaimaAutoSchedule.parse(data) else { throw TsukaimaIntentError("予定の応答を読めませんでした") }
        return s
    }
}

/// 授業の自動録音。オートメーションを授業の開始時刻に置くと、いまが「録音対象の授業の開始15分前〜終了」のときだけ録音を始める
/// (対象外の時刻・休講・すでに録音中なら何もしない)。録音は iOS 18 の AudioRecordingIntent としてバックグラウンドから始まり、
/// 本体が Live Activity(録音中の表示)を出す。止めるのは既存の自動停止(授業の終了の10分後)。
@available(iOS 18.0, *)
struct StartClassRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "授業の録音を始める"
    static let description = IntentDescription("時間割の授業のあいだだけ録音を始めます。対象の授業でなければ何もしません。オートメーションから使います。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = TsukaimaRecorderEngine.shared
        if engine.phase != .idle { return .result(dialog: "すでに録音中です") }
        let schedule: TsukaimaAutoSchedule
        do { schedule = try await TsukaimaAutoSchedules.fetch() } catch {
            throw TsukaimaIntentError("時間割を取得できませんでした: \(error.localizedDescription)")
        }
        guard let cls = schedule.classToRecord(at: Date()) else { return .result(dialog: "録音する授業はありません") }
        engine.start(course: cls.title)
        // 権限確認(許可済みなら即時)とマイクの起動を待つ。5秒で諦める
        for _ in 0..<50 where engine.phase == .idle {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if engine.phase == .idle { throw TsukaimaIntentError(engine.error ?? "録音を始められませんでした") }
        return .result(dialog: "\(cls.title)の録音を始めました")
    }
}

/// 技能教習の消音のための問い合わせ。技能教習の最中(または開始15分前から)なら、その技能が終わるまでの残り秒数を返す。
/// 学科だけの時間・教習のない日は 0。ショートカットで「0 より大きければ サイレントモード オン → その秒数待つ → オフ」と分岐する。
struct PracticalDrivingSecondsIntent: AppIntent {
    static let title: LocalizedStringResource = "技能教習の残り秒数"
    static let description = IntentDescription("技能教習の最中なら、終わるまでの秒数を返します。学科や教習のない時は 0 です。消音のショートカットから使います。")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let schedule: TsukaimaAutoSchedule
        do { schedule = try await TsukaimaAutoSchedules.fetch() } catch {
            throw TsukaimaIntentError("時間割を取得できませんでした: \(error.localizedDescription)")
        }
        return .result(value: schedule.silenceSeconds(at: Date()))
    }
}
