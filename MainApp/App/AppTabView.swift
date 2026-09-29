import SwiftUI

/// 下のタブバー: 今日 / 勉強 / 生活 / 使い魔 / 設定(docs/tsukaima-native-plan.md)。
/// 録音と目覚ましはどのタブを開いていても生きている必要があるので、ここで持って「使い魔」タブに渡す
/// (以前は TsukaimaTabView が持っていたが、最初に開くタブが「今日」になったため引き上げた)。
struct AppTabView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var rec = TsukaimaRecorderEngine()
    @StateObject private var alarm = TsukaimaAlarm()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $router.selectedTab) {
            TodayScreen()
                .tabItem {
                    AppTabItem(title: "今日", systemImage: "sun.max.fill")
                }
                .tag(AppRouter.Tab.today)
            StudyScreen()
                .tabItem {
                    AppTabItem(title: "勉強", systemImage: "book.fill")
                }
                .tag(AppRouter.Tab.study)
            LifeScreen()
                .tabItem {
                    AppTabItem(title: "生活", systemImage: "leaf.fill")
                }
                .tag(AppRouter.Tab.life)
            TsukaimaTabView(rec: rec, alarm: alarm)
                .tabItem {
                    AppTabItem(title: "使い魔", systemImage: "wand.and.stars")
                }
                .tag(AppRouter.Tab.tsukaima)
            AppSettingsTabView()
                .tabItem {
                    AppTabItem(title: "設定", systemImage: "gearshape.fill")
                }
                .tag(AppRouter.Tab.settings)
        }
        .onAppear { showAlarmIfNeeded() }
        .onChange(of: alarm.phase) { _, _ in showAlarmIfNeeded() }
        .onChange(of: phase, initial: true) { _, p in
            TsukaimaLog.add("scene \(p)")
            if p == .active {
                TsukaimaProvision.report()
                TsukaimaLog.upload()
                Task { await TsukaimaDiagnostics.shared.uploadKeyboardBreadcrumb() }
                TsukaimaImeDictSync.refreshIfNeeded()
                rec.foreground()
                showAlarmIfNeeded()
                TsukaimaDeviceAuth.refreshStepupKeyIfNeeded()
            }
        }
        #if HEALTHKIT
        // 前面に来るたび(最大 1 時間に 1 回)ヘルスケアを送る。手動送信は使い魔タブの「端末」/ショートカットから。
        .onChange(of: phase) { _, p in
            guard p == .active else { return }
            let key = "health.lastAutoSend"
            let now = Date().timeIntervalSince1970
            guard now - UserDefaults.standard.double(forKey: key) > 3600 else { return }
            UserDefaults.standard.set(now, forKey: key)
            Task {
                guard (try? await HealthBridge.requestAuthorization()) != nil else { return }
                let body = await HealthBridge.snapshotForUpload()
                _ = try? await TsukaimaNet.postJSON(TsukaimaHub.healthURL, body)
            }
        }
        #endif
    }

    /// 鳴っている・二度寝チェック中は、どのタブにいても「使い魔」タブ(目覚まし)へ
    private func showAlarmIfNeeded() {
        if alarm.phase == .ringing || alarm.phase == .checking {
            router.selectedTab = .tsukaima
        }
    }
}

/// 「設定」タブ: 使い魔の設定(SettingsScreen)と、azooKey のキーボード設定一式(設定・拡張・着せ替え・使い方)
struct AppSettingsTabView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $router.settingsSection) {
                Text("使い魔").tag(AppRouter.SettingsSection.tsukaima)
                Text("キーボード").tag(AppRouter.SettingsSection.keyboard)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            if router.settingsSection == .keyboard {
                Picker("", selection: $router.keyboardTab) {
                    Text("設定").tag(AppRouter.Tab.settings)
                    Text("拡張").tag(AppRouter.Tab.customization)
                    Text("着せ替え").tag(AppRouter.Tab.theme)
                    Text("使い方").tag(AppRouter.Tab.tips)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            Group {
                switch (router.settingsSection, router.keyboardTab) {
                case (.tsukaima, _): SettingsScreen()
                case (.keyboard, .customization): CustomizationHomeView()
                case (.keyboard, .theme): ThemeHomeView()
                case (.keyboard, .tips): TipsHomeView()
                case (.keyboard, _): SettingsHomeView()
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AppTabItem: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.systemGray2)
            Text(title)
        }
    }
}
