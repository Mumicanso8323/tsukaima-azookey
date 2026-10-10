import SwiftUI

/// 「使い魔」タブ: 使い魔とのチャット(ChatScreen)・録音・目覚まし・この端末(登録/接続)。
/// 録音エンジンと目覚ましは AppTabView が持つ(どのタブを開いていても生きているように)。
/// シーン監視(前面復帰時の期限報告・ログ送信・ヘルスケア送信)も AppTabView 側。
struct TsukaimaTabView: View {
    @EnvironmentObject private var router: AppRouter
    @ObservedObject var rec: TsukaimaRecorderEngine
    @ObservedObject var alarm: TsukaimaAlarm
    @State private var innerTab: Int

    enum Inner {
        static let record = 0
        static let alarm = 1
        static let device = 2
        static let chat = 3
        static let converse = 4
        static let blind = 5
    }

    // 鳴っている・二度寝チェック中に(通知タップ・OS の再起動などで)開いたときは、
    // 最初のフレームから問題画面。ほかのタブが一瞬でも見える隙を作らない。
    init(rec: TsukaimaRecorderEngine, alarm: TsukaimaAlarm) {
        _rec = ObservedObject(wrappedValue: rec)
        _alarm = ObservedObject(wrappedValue: alarm)
        _innerTab = State(initialValue: (alarm.phase == .ringing || alarm.phase == .checking) ? Inner.alarm : Inner.chat)
    }

    var body: some View {
        // 外側(アプリ全体)のタブバーと二段に重ならないよう、中の切り替えは上端のセグメントにする。
        VStack(spacing: 0) {
            Picker("", selection: $innerTab) {
                Text("チャット").tag(Inner.chat)
                Text("会話").tag(Inner.converse)
                Text("ブラインド").tag(Inner.blind)
                Text("録音").tag(Inner.record)
                Text("目覚まし").tag(Inner.alarm)
                Text("端末").tag(Inner.device)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tsukaima.innerTabs")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Group {
                switch innerTab {
                case Inner.alarm: TsukaimaAlarmView(alarm: alarm)
                case Inner.device: TsukaimaKitSettingsView()
                case Inner.record: TsukaimaRecorderView(rec: rec)
                case Inner.converse: ConverseStatusView()
                case Inner.blind: BlindScreen { innerTab = Inner.chat }
                default: ChatScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .recordingBannerOnTop(rec)
        .preferredColorScheme(.dark)
        .onChange(of: alarm.phase) { _, p in if p != .off && p != .armed { innerTab = Inner.alarm } }
        .onChange(of: router.tsukaimaRecordRequest) { _, request in
            guard let request else { return }
            innerTab = Inner.record
            rec.start(course: request.course)
        }
        .onChange(of: router.selectedTab) { _, tab in
            if tab == .tsukaima, alarm.phase == .ringing || alarm.phase == .checking { innerTab = Inner.alarm }
        }
        .onAppear {
            if alarm.phase == .ringing || alarm.phase == .checking { innerTab = Inner.alarm }
        }
    }
}
