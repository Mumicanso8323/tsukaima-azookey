import AppIntents

/// 画面を一切見ずに会話モードを開始・終了する(Siri・ショートカット・アクションボタンから呼べる)。
/// openAppWhenRun は false: 前面に出さず、アプリのプロセス内で ConverseEngine.shared を直接操作する
/// (UIBackgroundModes の audio があるので、開始後はアプリを閉じても録音・再生が続く)。
struct StartConverseIntent: AppIntent {
    static let title: LocalizedStringResource = "使い魔と会話を始める"
    static let description = IntentDescription("画面を見ずに、声だけで Claude Code を動かす会話モードを始めます。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            try ConverseEngine.shared.start()
        } catch {
            // 画面を見ずにショートカット/アクションボタンから呼ぶので、失敗は端末の声でも伝える(A6・S22)
            let text = (error as NSError).domain == "converse"
                ? error.localizedDescription
                : "マイクが使えないので会話モードを始められません。" + error.localizedDescription
            ConverseEngine.shared.announce(text)
            throw TsukaimaIntentError(text)
        }
        return .result(dialog: "会話を始めます")
    }
}

struct StopConverseIntent: AppIntent {
    static let title: LocalizedStringResource = "使い魔との会話を終える"
    static let description = IntentDescription("会話モードを終えます。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        ConverseEngine.shared.stop()
        return .result(dialog: "会話を終えました")
    }
}
