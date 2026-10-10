import AzooKeyUtils
import KeyboardViews

enum AppLaunchTasks {
    @MainActor
    static func performInitialSetup() {
        SemiStaticStates.shared.setup()
        SharedStore.setInitialAppVersion()
        SharedStore.setLastAppVersion()

        var messageManager = MessageManager()
        messageManager.getMessagesContainerAppShouldMakeWhichDone().forEach {
            messageManager.done($0.id)
        }

        if let initialVersion = SharedStore.initialAppVersion, initialVersion > .azooKey_v2_2_2 {
            KeepDeprecatedShiftKeyBehavior.value = false
        }

        if let initialVersion = SharedStore.initialAppVersion,
           initialVersion >= .azooKey_v3_1,
           UseShiftKey.get() == nil {
            UseShiftKey.value = true
        }
    }

    @MainActor
    static func performMaintenance() async {
        do {
            try await HotfixDictionaryV1.updateIfRequired()
        } catch {
            print(error)
        }
        UserDictionaryMigrationRunner.runIfNeeded()

        // 使い魔: MetricKit 購読・ビルド番号・キーボードのパンくずを hub へ(docs/tsukaima-native-plan.md)。
        TsukaimaDiagnostics.shared.start()
        await TsukaimaDiagnostics.shared.reportLaunch()
        await TsukaimaDiagnostics.shared.uploadKeyboardBreadcrumb()
    }
}
