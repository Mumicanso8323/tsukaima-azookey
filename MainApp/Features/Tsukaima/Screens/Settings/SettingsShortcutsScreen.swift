import SwiftUI
import UIKit

/// 設定 → ショートカット連携。帰る前のチェックリストの編集と、iPhone のオートメーション設定の手引き(Web 版と同じ内容)。
struct SettingsShortcutsScreen: View {
    @State private var checklist = ""
    @State private var clMsg: String?
    @State private var busy = false
    @State private var copied: String?

    private static let base = "https://api.yusukedoi.com"
    private static let healthJSON = #"{"date":"2026-09-26","steps":8000,"flights":5,"active_kcal":320,"sleep_hours":7.2,"resting_hr":58}"#

    var body: some View {
        Form {
            Section {
                Text("iPhone の「ショートカット」アプリでオートメーションを作ると、使い魔が自動で記録します。送り先は api.yusukedoi.com なので、どこにいても届きます(Tailscale は不要)。URL の内容を取得のヘッダに X-Automation-Token(設定 → 端末の「自動化トークンを発行してコピー」で出した値)を入れてください。")
                    .font(.footnote)
            }

            Section {
                TsukaimaComposerField(placeholder: "タオル、イヤホン、学生証", text: $checklist, maxLines: 4,
                                      textInset: UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
                HStack {
                    Button(busy ? "保存中…" : "保存") { Task { await saveChecklist() } }
                        .disabled(busy)
                    if let clMsg { Text(clMsg).font(.footnote).foregroundStyle(.secondary) }
                }
            } header: {
                Text("帰る前のチェックリスト")
            } footer: {
                Text("「外出」オートメーションの通知と、朝 7:00 のまとめ通知(授業がある日)に使います。読点(、)区切りで入力。")
            }

            Section {
                DisclosureGroup("設定手順") {
                    Text("""
                    1. ショートカット App →「オートメーション」タブ → 右上の ＋ →「個人用オートメーションを作成」
                    2.「時刻」を選ぶ → 例: 23:50、繰り返し「毎日」→「次へ」
                    3.「すぐに実行」をオンにする(確認画面を出さない)
                    4.「アクションを追加」→「ヘルスケアサンプルを検索」を、歩数・上る階数・アクティブエネルギー・睡眠分析・安静時心拍数の分だけ追加(期間は「今日」)
                    5. それぞれの後ろに「統計を計算」を追加(歩数・階数・アクティブエネルギーは合計、安静時心拍数は平均、睡眠は合計を時間に換算)
                    6.「辞書を作成」を追加し、キーを date・steps・flights・active_kcal・sleep_hours・resting_hr にして、それぞれ手順4〜5の変数を割り当てる(date は「現在の日付」を yyyy-MM-dd 形式で)
                    7.「URL の内容を取得」を追加: 方法「POST」、ヘッダに X-Automation-Token(自動化トークン)を追加、本文の種類「JSON」、本文に手順6の辞書を指定して保存
                    """).font(.footnote)
                }
                copyRow(Self.base + "/api/health", label: "URL をコピー")
                copyRow(Self.healthJSON, label: "JSON をコピー")
                Text("sleep_hours・resting_hr は無くても送れます。他の数値キーを足しても記録されます(表には出ません)。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("① ヘルスケア(1 日 1 回・時刻オートメーション)")
            }

            Section("② スクショを出費に") {
                Text("ショートカットのオートメーションのアクションで「使い魔キット」の「スクショを出費に」を選ぶ。スクリーンショットを撮るなどのトリガーは自分で選び、画像をこのアクションに渡してください(OCR は端末上で行います)。")
                    .font(.footnote)
            }
            Section("③ Apple Pay(Wallet の取引)") {
                Text("Wallet の取引オートメーションのアクションで「使い魔キット」の「Apple Pay を記録」を選ぶ。トリガー(カード・取引の直後)はこれまで通り自分で選び、店名・金額・カード名をアクションのパラメータに割り当ててください。")
                    .font(.footnote)
            }
            Section("④ 在不在(Wi-Fi・充電器)") {
                Text("Wi-Fi/充電器のオートメーションのアクションで「使い魔キット」の「在不在を記録」を選び、イベント(外出/帰宅/就寝)を選ぶだけ。トリガー(自宅の Wi-Fi・充電器・時間帯の絞り込み)はこれまで通り自分で選んでください。")
                    .font(.footnote)
            }
            Section("⑤ 使い魔に送る(写真・PDF・CSV を何でも自動で仕分け)") {
                Text("Files・写真・Adobe Scan などの共有メニューに「使い魔に送る」が出ます(複数選択も可、ショートカットを作る必要はありません)。Adobe Scan の PDF、レシート・PayPay のスクショ、食事の写真、CSV(PayPay の取引履歴)を送ると内容を見て自動で振り分けます。")
                    .font(.footnote)
            }
            Section("⑥ 使い魔に送る(ルルブ)") {
                Text("共有メニューの「使い魔に送る」で「ルルブとして送る」をオンにし、system/book(例: nechronica/基本ルールブック)を入れてから送る。オーナー個人が所有する本を自分用に参照するための機能で、公開・配布はしません。進捗は GET /api/rulebooks で確認できます。")
                    .font(.footnote)
            }
        }
        .navigationTitle("ショートカット連携")
        .navigationBarTitleDisplayMode(.inline)
        .tsukaimaTextSize()
        .task { await loadChecklist() }
    }

    private func copyRow(_ value: String, label: String) -> some View {
        HStack(alignment: .top) {
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button(copied == value ? "コピーしました ✓" : label) {
                UIPasteboard.general.string = value
                copied = value
                Task {
                    try? await Task.sleep(for: .milliseconds(1600))
                    if copied == value { copied = nil }
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    private func loadChecklist() async {
        if let cl = try? await CSNet.get("/api/leave-checklist", as: SettingsChecklist.self) {
            checklist = cl.items.joined(separator: "、")
        }
    }

    private func saveChecklist() async {
        let items = checklist.components(separatedBy: CharacterSet(charactersIn: "、,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        busy = true
        defer { busy = false }
        clMsg = "保存中…"
        do {
            let r = try await CSNet.send("POST", "/api/leave-checklist", json: ["items": items], as: SettingsChecklist.self)
            checklist = r.items.joined(separator: "、")
            clMsg = "✓ 保存しました"
        } catch {
            clMsg = "保存できませんでした: " + CSNet.message(error)
        }
    }
}
