import SwiftUI

/// 下のタブバー: ホーム(今日/勉強/生活) / 使い魔 / 設定(docs/tsukaima-native-plan.md)。
/// 録音と目覚ましはどのタブを開いていても生きている必要があるので、ここで持って「使い魔」タブに渡す
/// (以前は TsukaimaTabView が持っていたが、最初に開くタブが「今日」になったため引き上げた)。
/// rec は environmentObject でも配って、今日タブがその場で録音の開始/停止をできるようにする。
struct AppTabView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var rec = TsukaimaRecorderEngine()
    @StateObject private var alarm = TsukaimaAlarm()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $router.selectedTab) {
            HomeTabView()
                .tabItem {
                    AppTabItem(title: "ホーム", systemImage: "house.fill")
                }
                .tag(AppRouter.Tab.home)
            TsukaimaTabView(rec: rec, alarm: alarm)
                .tabItem {
                    AppTabItem(title: "使い魔", systemImage: "wand.and.stars")
                }
                .tag(AppRouter.Tab.tsukaima)
            ClaudeTabView()
                .tabItem {
                    AppTabItem(title: "Claude", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(AppRouter.Tab.claude)
            AppSettingsTabView()
                .tabItem {
                    AppTabItem(title: "設定", systemImage: "gearshape.fill")
                }
                .tag(AppRouter.Tab.settings)
        }
        .environmentObject(rec)
        // どのタブにいても録音中がわかる小さな帯(今日タブから録音を始めても他のタブに移動できるように)
        .safeAreaInset(edge: .top) {
            if rec.phase != .idle {
                TsukaimaRecordingBanner(rec: rec)
            }
        }
        .onAppear { showAlarmIfNeeded() }
        .onChange(of: alarm.phase) { _, _ in showAlarmIfNeeded() }
        .onChange(of: phase, initial: true) { _, p in
            TsukaimaLog.add("scene \(p)")
            // UI テスト(ClaudeConfig.isMock)では権限の確認ダイアログ・通信を伴う起動時処理を走らせない
            // (シミュレータで通知/位置情報の許可ダイアログが出ると入力欄からキーボードを奪うため)。
            // 録音エンジンの foreground は残す(ルートの再描画が起きる実機と同じ状況でテストする)。
            if ClaudeConfig.isMock {
                if p == .active { rec.foreground() }
                return
            }
            if p == .active {
                TsukaimaProvision.report()
                TsukaimaLog.upload()
                Task { await TsukaimaDiagnostics.shared.uploadKeyboardBreadcrumb() }
                TsukaimaImeDictSync.refreshIfNeeded()
                rec.foreground()
                alarm.applicationDidLaunchOrForeground()  // 目覚ましの生存と AlarmKit の保険を点検し直す
                showAlarmIfNeeded()
                TsukaimaDeviceAuth.refreshStepupKeyIfNeeded()
                TsukaimaLocationService.shared.applicationDidLaunchOrForeground()
                TsukaimaPhotoBackup.shared.applicationDidLaunchOrForeground()
            } else if p == .background {
                TsukaimaLocationService.shared.applicationDidEnterBackground()
                TsukaimaPhotoBackup.shared.applicationDidEnterBackground()
            }
        }
        #if HEALTHKIT
        // 前面に来るたび(最大 1 時間に 1 回)ヘルスケアを送る。手動送信は使い魔タブの「端末」/ショートカットから。
        .onChange(of: phase) { _, p in
            guard p == .active, !ClaudeConfig.isMock else { return }
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

/// 「ホーム」タブ: 今日 / 勉強 / 生活 を上部セグメントで切り替える(使い魔タブと同じパターン)。
/// 最後に選んだセグメントは AppStorage で覚えておく。
struct HomeTabView: View {
    enum Segment: String {
        case today
        case study
        case life
    }

    // CSTextSize 等と同じく、AppStorage には rawValue(String)を入れる
    @AppStorage("home.segment") private var segmentRaw = Segment.today.rawValue
    private var segment: Segment { Segment(rawValue: segmentRaw) ?? .today }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { segment }, set: { segmentRaw = $0.rawValue })) {
                Text("今日").tag(Segment.today)
                Text("勉強").tag(Segment.study)
                Text("生活").tag(Segment.life)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Group {
                switch segment {
                case .today: TodayScreen()
                case .study: StudyScreen()
                case .life: LifeScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// どのタブを見ていても録音中がわかる帯。今日タブでその場で録音を始めた後、
/// 他のタブに移っても止め忘れないように(停止は使い魔タブの「録音」からもできる)。
struct TsukaimaRecordingBanner: View {
    @ObservedObject var rec: TsukaimaRecorderEngine

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.white).frame(width: 8, height: 8)
            if rec.phase == .recording {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("● 録音中 \(TodayRecordingCard.mmss(rec.startedAt, at: ctx.date))")
                }
            } else {
                Text("● 文字起こしを仕上げ中…")
            }
            Spacer(minLength: 8)
            if rec.phase == .recording {
                Button("停止") { rec.stop() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.25), in: Capsule())
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.red)
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
