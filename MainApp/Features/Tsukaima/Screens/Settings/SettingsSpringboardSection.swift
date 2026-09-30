import SwiftUI
import UniformTypeIdentifiers

/// ホーム画面のアイコン配置(実験・読み取り専用)。
/// docs/tsukaima-springboard-icon-integration.md の組み込み手順に対応する最小のデモ画面:
/// ペアリングファイルの取り込みと「読み取ってみる」ボタンだけ(依頼の「並べ替えはサーバーから配置案を
/// 受け取って確認してから適用する」設計は、まず疎通が取れてから乗せる次段。今回は読み取りまで)。
struct SettingsSpringboardSection: View {
    @State private var hasPairingFile = TsukaimaPairingFileStore.exists
    @State private var isImporting = false
    @State private var isReading = false
    @State private var summary: TsukaimaIconStateSummary?
    @State private var message: String?

    var body: some View {
        Section {
            HStack {
                Text("ペアリングファイル")
                Spacer()
                Text(hasPairingFile ? "取り込み済み" : "未取り込み").foregroundStyle(.secondary)
            }
            Button(hasPairingFile ? "ペアリングファイルを入れ直す" : "ペアリングファイルを取り込む") {
                isImporting = true
            }
            if hasPairingFile {
                Button("削除", role: .destructive) {
                    TsukaimaPairingFileStore.remove()
                    hasPairingFile = false
                    summary = nil
                }
            }
            Button("ホーム画面を読み取る(実験)") {
                Task { await read() }
            }
            .disabled(!hasPairingFile || isReading)
            if isReading {
                HStack { ProgressView(); Text("接続中…(LocalDevVPN 経由)").foregroundStyle(.secondary) }
            }
            if let summary {
                HStack { Text("ページ数"); Spacer(); Text(summary.pageCount.map(String.init) ?? "不明").foregroundStyle(.secondary) }
                HStack { Text("Dock のアプリ数"); Spacer(); Text(summary.dockAppCount.map(String.init) ?? "不明").foregroundStyle(.secondary) }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("ホーム画面の配置(実験)")
        } footer: {
            Text("LocalDevVPN(SideStore で使っているのと同じもの)に接続した状態で、この端末自身の lockdownd から現在の配置を読み取るだけの実験機能です。並べ替えて適用する機能はまだありません。ペアリングファイルの中身は画面にもログにも一切出しません。")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.propertyList, .data, .item]) { result in
            switch result {
            case .success(let url):
                do {
                    try TsukaimaPairingFileStore.importFile(from: url)
                    hasPairingFile = true
                    message = nil
                } catch {
                    message = "取り込めませんでした"
                }
            case .failure:
                message = "取り込めませんでした"
            }
        }
    }

    private func read() async {
        guard let data = TsukaimaPairingFileStore.load() else {
            message = "ペアリングファイルがありません"
            return
        }
        isReading = true
        message = nil
        defer { isReading = false }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try TsukaimaIdeviceBridge.readIconStateSummary(pairingFileData: data) }
        }.value
        switch result {
        case .success(let s):
            summary = s
        case .failure(let error):
            summary = nil
            message = (error as? LocalizedError)?.errorDescription ?? "読み取れませんでした"
        }
    }
}
