import SwiftUI

/// 「使い魔」タブのルート。旧 使い魔キット(TsukaimaRecorder)アプリの中身(録音・目覚まし・設定)を、
/// azooKey 本体の1タブとして表示する。元アプリの @main 構造体が持っていたシーン監視・URLオープン
/// 処理はここに移した(ルーティング自体は AppRouter が担う。tsukaima-rec:// は AppRouter.open 経由)。
struct TsukaimaTabView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var rec = TsukaimaRecorderEngine()
    @StateObject private var alarm: TsukaimaAlarm
    @State private var innerTab: Int
    @Environment(\.scenePhase) private var phase

    // 鳴っている・二度寝チェック中に(通知タップ・OS の再起動などで)開いたときは、
    // 最初のフレームから問題画面。録音タブが一瞬でも見える隙を作らない。
    init() {
        let a = TsukaimaAlarm()
        _alarm = StateObject(wrappedValue: a)
        _innerTab = State(initialValue: (a.phase == .ringing || a.phase == .checking) ? 1 : 0)
    }

    var body: some View {
        // 外側(アプリ全体)のタブバーと二段に重ならないよう、中の切り替えは上端のセグメントにする。
        VStack(spacing: 0) {
            Picker("", selection: $innerTab) {
                Label("録音", systemImage: "mic").tag(0)
                Label("目覚まし", systemImage: "alarm").tag(1)
                Label("設定", systemImage: "gearshape").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Group {
                switch innerTab {
                case 1: TsukaimaAlarmView(alarm: alarm)
                case 2: TsukaimaKitSettingsView()
                default: TsukaimaRecorderView(rec: rec)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .onChange(of: alarm.phase) { _, p in if p != .off && p != .armed { innerTab = 1 } }
        .onChange(of: router.tsukaimaRecordRequest) { _, request in
            guard let request else { return }
            innerTab = 0
            rec.start(course: request.course)
        }
        .onChange(of: router.selectedTab) { _, tab in
            if tab == .tsukaima, alarm.phase == .ringing || alarm.phase == .checking { innerTab = 1 }
        }
        .onChange(of: phase, initial: true) { _, p in
            TsukaimaLog.add("scene \(p)")
            if p == .active {
                TsukaimaProvision.report()
                TsukaimaLog.upload()
                rec.foreground()
                if alarm.phase == .ringing || alarm.phase == .checking { innerTab = 1 }
            }
        }
        #if HEALTHKIT
        // 前面に来るたび(最大 1 時間に 1 回)ヘルスケアを送る。手動送信は設定タブのボタン/ショートカットから。
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
}
