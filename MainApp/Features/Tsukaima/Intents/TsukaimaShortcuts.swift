import AppIntents

/// ここに登録した Intent は import しなくても Shortcuts アプリ・オートメーションの候補に自動で出る
/// (.shortcut ファイルのインポートが不要になる)。
struct TsukaimaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordPresenceIntent(),
            phrases: [
                "\(.applicationName) で在不在を記録",
                "\(.applicationName) に在不在を伝える",
            ],
            shortTitle: "在不在を記録",
            systemImageName: "house"
        )
        AppShortcut(
            intent: RecordApplePayIntent(),
            phrases: [
                "\(.applicationName) で Apple Pay を記録",
                "\(.applicationName) に支払いを記録",
            ],
            shortTitle: "Apple Pay を記録",
            systemImageName: "creditcard"
        )
        AppShortcut(
            intent: ScreenshotToSpendIntent(),
            phrases: [
                "\(.applicationName) でスクショを出費に",
            ],
            shortTitle: "スクショを出費に",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: StartConverseIntent(),
            phrases: [
                "\(.applicationName) と会話を始める",
                "\(.applicationName) で会話を始める",
            ],
            shortTitle: "会話を始める",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: StopConverseIntent(),
            phrases: [
                "\(.applicationName) との会話を終える",
                "\(.applicationName) の会話を終える",
            ],
            shortTitle: "会話を終える",
            systemImageName: "waveform.slash"
        )
        #if HEALTHKIT
        AppShortcut(
            intent: SendHealthIntent(),
            phrases: [
                "\(.applicationName) でヘルスケアを送る",
            ],
            shortTitle: "ヘルスケアを送る",
            systemImageName: "heart"
        )
        #endif
    }
}
