// HealthBridge.swift 冒頭のコメント参照: HealthKit は既定で無効(HEALTHKIT フラグが立つまで
// コンパイルされない)。この intent 自体も同じ理由でフラグの中に入れ、無効ビルドでは
// AppShortcutsProvider にも一切出てこないようにする。
#if HEALTHKIT
import AppIntents

struct SendHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "ヘルスケアを送る"
    static let description = IntentDescription("今日の歩数・上った階数・アクティブエネルギー・安静時心拍数・前夜の睡眠時間を使い魔に送ります。")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            try await HealthBridge.requestAuthorization()
        } catch {
            throw TsukaimaIntentError("ヘルスケアへのアクセスが許可されていません")
        }
        let body = await HealthBridge.snapshotForUpload()
        do {
            _ = try await TsukaimaNet.postJSON(TsukaimaHub.healthURL, body)
        } catch {
            throw TsukaimaIntentError("送信に失敗しました: \(error.localizedDescription)")
        }
        return .result(dialog: "送りました")
    }
}
#endif
