import SwiftUI

/// 使い魔キット(録音・目覚まし)のミニ設定: 接続先 hub の表示、プロビジョニング期限の再送、
/// (有効時のみ)ヘルスケア許可ボタン。アプリ全体のバージョン・更新履歴は azooKey 本体の
/// 「設定」タブ側(About)を参照。
struct TsukaimaKitSettingsView: View {
    #if HEALTHKIT
    @State private var healthStatus = "未確認"
    #endif
    @State private var reported = false

    var body: some View {
        NavigationView {
            Form {
                Section("接続先") {
                    LabeledContent("hub", value: TsukaimaHub.host)
                }
                Section {
                    Button(reported ? "送信しました" : "署名の期限を hub に知らせる") {
                        TsukaimaProvision.report()
                        reported = true
                    }
                } footer: {
                    Text("SideStore の再署名が近づくと、hub 側から通知してもらうための情報です。")
                }
                #if HEALTHKIT
                Section("ヘルスケア") {
                    Text(healthStatus).font(.footnote).foregroundStyle(.secondary)
                    Button("ヘルスケアへのアクセスを許可") {
                        Task {
                            do {
                                try await HealthBridge.requestAuthorization()
                                healthStatus = "許可されました"
                            } catch {
                                healthStatus = "許可できませんでした"
                            }
                        }
                    }
                }
                #endif
            }
            .navigationTitle("使い魔キットの設定")
        }
    }
}
