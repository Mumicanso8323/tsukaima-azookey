import SwiftUI

/// 「設定」タブ。Web 版 app.js の settings と同じ項目を並べる。
/// 危ない操作(金庫・カード・端末の取り消し・Classroom/iCloud のログイン情報)は Face ID のステップアップつき(stepup: true)。
/// 通知(Web Push)は Web 版(ホーム画面の PWA)に残すので、ここでは案内だけ出す。
struct SettingsScreen: View {
    @AppStorage(CSTextSize.storageKey) private var textSize = CSTextSize.standard.rawValue
    @State private var links: SettingsTodayLinks?
    @State private var alarmEnabled: Bool?
    @State private var alarmMsg: String?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Form {
                SettingsPairingSlot()

                Section {
                    Picker("文字の大きさ", selection: $textSize) {
                        ForEach(CSTextSize.allCases) { s in Text(s.label).tag(s.rawValue) }
                    }
                } header: {
                    Text("表示")
                } footer: {
                    Text("使い魔タブと設定タブの文字の大きさ。iOS の「画面表示と明るさ → テキストサイズ」にも従います。")
                }

                Section {
                    Text("通知(お知らせ・毎朝のまとめ・起床)は、これまでどおりホーム画面の Web 版「使い魔」で受け取ります。通知のオン・テストは Web 版の設定から行ってください。")
                        .font(.footnote)
                } header: {
                    Text("通知")
                }

                Section {
                    if let alarmEnabled {
                        Toggle("授業がある日は起床アラームを自動セット", isOn: Binding(
                            get: { alarmEnabled },
                            set: { v in Task { await setAlarm(v) } }))
                    } else {
                        HStack { Text("起床アラーム"); Spacer(); ProgressView() }
                    }
                    if let alarmMsg { Text(alarmMsg).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text("起床アラーム")
                } footer: {
                    Text("iPhone のアラームを音量最大で鳴らす・バンドを振動させる手順は、Web 版の「起床アラームの設定手順」を見てください。")
                }

                Section {
                    NavigationLink {
                        SettingsShortcutsScreen()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ショートカット連携")
                            Text("帰る前のチェックリスト・ヘルスケア・PayPay・Apple Pay・在不在・使い魔に送る")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("iPhone のショートカット連携")
                }

                Section {
                    NavigationLink {
                        SettingsSnippetsScreen()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("定型文")
                            Text("読みを打つとキーボードの候補に本文が出る(署名・学籍番号など)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("使い魔キーの辞書")
                } footer: {
                    Text("授業名・教員名・TRPG 用語の自動辞書は毎朝更新されます。ここで編集できるのは定型文だけです。")
                }

                Section {
                    if let g = links?.google {
                        if g.configured != true {
                            Text("hub 側の準備(Google の OAuth クライアント)がまだです。")
                        } else if let accts = g.accounts, !accts.isEmpty {
                            ForEach(accts, id: \.self) { a in Label(a, systemImage: "checkmark") }
                        } else {
                            Text("未連携")
                        }
                    } else if loadError == nil {
                        ProgressView()
                    }
                } header: {
                    Text("大学の Google アカウント(メール・カレンダー)")
                } footer: {
                    Text("アカウントの追加は Google のログイン画面を使うので、Web 版の設定から行ってください。")
                }

                SettingsICloudSection(configured: links?.icloud == true)
                SettingsGAuthSection(password: links?.gauth?.password == true, totp: links?.gauth?.totp == true)
                SettingsVaultSection()
                SettingsCardSection()
                SettingsDevicesSection()
                SettingsAutomationTokenSection()

                Section {
                    Text("ポータルは毎朝 6:50 と日中 2 時間ごと、メールは 10 分ごとに確認。重要なものだけ即時通知、毎朝 7:00 に今日のまとめを通知します。授業がある日は起床時刻にも通知を繰り返します(唯一の夜間例外)。録音した音声は保存せず、文字起こしだけ残します。")
                        .font(.footnote)
                } header: {
                    Text("このアプリについて")
                }

                if let loadError {
                    Section { Text(loadError).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task { await load() }
        }
        .tsukaimaTextSize()
    }

    private func load() async {
        do {
            links = try await CSNet.get("/api/today", as: SettingsTodayLinks.self)
            loadError = nil
        } catch {
            loadError = "読み込めませんでした: " + CSNet.message(error)
        }
        if let a = try? await CSNet.get("/api/alarm/settings", as: SettingsAlarm.self) {
            alarmEnabled = a.enabled
        }
    }

    private func setAlarm(_ v: Bool) async {
        let before = alarmEnabled
        alarmEnabled = v
        do {
            let a = try await CSNet.send("POST", "/api/alarm/settings", json: ["enabled": v], as: SettingsAlarm.self)
            alarmEnabled = a.enabled
            alarmMsg = nil
        } catch {
            alarmEnabled = before
            alarmMsg = "変更できませんでした: " + CSNet.message(error)
        }
    }
}
