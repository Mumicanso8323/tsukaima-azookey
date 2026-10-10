import FamilyControls
import SwiftUI

/// 設定 →「バイト中のブロック」。ブロックするアプリを選び、試しに今から一定時間だけ盾を立てる。
struct WorkShiftBlockView: View {
    @State private var selection = WorkShiftBlockCore.loadSelection()
    @State private var pickerShown = false
    @State private var status = AuthorizationCenter.shared.authorizationStatus
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text(statusText).font(.footnote).foregroundStyle(.secondary)
                Button("スクリーンタイムの利用を許可") { Task { await authorize() } }
                    .disabled(status == .approved)
            } header: {
                Text("許可")
            } footer: {
                Text("Face ID か端末のパスコードで本人確認をします。スクリーンタイムのパスコード(保護者が設定したもの)は使いません。")
            }
            Section {
                Button("ブロックするアプリを選ぶ") { pickerShown = true }
                    .disabled(status != .approved)
                Text("選んだアプリ \(selection.applicationTokens.count) 件・カテゴリ \(selection.categoryTokens.count) 件・サイト \(selection.webDomainTokens.count) 件")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("対象")
            } footer: {
                Text("アプリの一覧は OS の画面で選びます。ここでは名前は見えません(選んだ内容はこの端末の外へ出ません)。")
            }
            Section {
                Button("今から15分ブロック") { startTest() }
                    .disabled(status != .approved || isEmpty)
                Button("ブロックを今すぐ解除", role: .destructive) {
                    WorkShiftBlockCore.cancelAllShifts()
                    message = "解除しました。"
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("試す")
            } footer: {
                Text("区間の長さは OS の制約で15分が最短です。使い魔自身を選ぶと、ブロック中はこの画面も開けなくなります。")
            }
        }
        .navigationTitle("バイト中のブロック")
        .familyActivityPicker(isPresented: $pickerShown, selection: $selection)
        .onChange(of: selection) { _, new in WorkShiftBlockCore.saveSelection(new) }
    }

    private var isEmpty: Bool {
        selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
    }

    private var statusText: String {
        switch status {
        case .approved: return "許可されています。"
        case .denied: return "許可されていません。"
        default: return "まだ許可していません。"
        }
    }

    private func authorize() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            message = nil
        } catch {
            // 例: entitlement が無い署名・Family Sharing の子アカウント・端末のパスコード未設定など
            message = "許可できませんでした: \(error.localizedDescription)(\((error as NSError).domain) \((error as NSError).code))"
        }
        status = AuthorizationCenter.shared.authorizationStatus
    }

    private func startTest() {
        do {
            try WorkShiftBlockCore.startTestBlock(minutes: 15)
            message = "15分のブロックを始めました。"
        } catch {
            message = "始められませんでした: \(error.localizedDescription)"
        }
    }
}
