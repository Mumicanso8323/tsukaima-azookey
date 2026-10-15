import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// ホーム画面のアイコン配置(設定タブの入口)。
/// ここではペアリングファイルの取り込み(SideStore から / ファイルから)と、配置画面
/// (TsukaimaSpringboardLayoutView: 読み取り → 配置案 → 差分 → 適用 → 元に戻す)への導線だけ。
/// 手順は docs/tsukaima-springboard-icon-integration.md §7。
struct SettingsSpringboardSection: View {
    @EnvironmentObject private var router: AppRouter
    @State private var hasPairingFile = TsukaimaPairingFileStore.exists
    @State private var vpnOn = TsukaimaIdeviceBridge.isVPNInterfacePresent()
    @State private var isImporting = false
    @State private var message: String?

    var body: some View {
        Section {
            NavigationLink {
                TsukaimaSpringboardLayoutView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ホーム画面の配置")
                    Text("hub の配置案を差分で確認して適用・元に戻す")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("端末内 VPN(StosVPN)")
                Spacer()
                Text(vpnOn ? "接続中" : "OFF").foregroundStyle(vpnOn ? Color.secondary : Color.red)
            }
            HStack {
                Text("ペアリングファイル")
                Spacer()
                Text(hasPairingFile ? "取り込み済み" : "未取り込み").foregroundStyle(hasPairingFile ? Color.secondary : Color.red)
            }
            Button("SideStore から取り込む") { importFromSideStore() }
            Button(hasPairingFile ? "ファイルから入れ直す" : "ファイルから取り込む") { isImporting = true }
            if hasPairingFile {
                Button("ペアリングファイルを削除", role: .destructive) {
                    TsukaimaPairingFileStore.remove()
                }
            }
            if router.pairingFileImportSucceeded == false {
                Text("SideStore から受け取ったデータをペアリングファイルとして読み取れませんでした。SideStore にペアリングファイルが入っているか確認してください。")
                    .font(.footnote).foregroundStyle(.red)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("ホーム画面の配置")
        } footer: {
            Text("Wi-Fi も PC も要りません。SideStore と同じ端末内 VPN(StosVPN)を ON にして、この iPhone 自身に繋ぎます。ペアリングファイルは SideStore に入っているものをそのまま受け取れます(SideStore が対応していない版なら、PC の jitterbugpair で作った plist をファイルから取り込みます)。中身は画面にもログにも一切出しません。")
        }
        .onReceive(NotificationCenter.default.publisher(for: TsukaimaPairingFileStore.didChange)) { _ in
            hasPairingFile = TsukaimaPairingFileStore.exists
            if hasPairingFile {
                message = nil
                router.pairingFileImportSucceeded = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            vpnOn = TsukaimaIdeviceBridge.isVPNInterfacePresent()
            hasPairingFile = TsukaimaPairingFileStore.exists
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.propertyList, .data, .item]) { result in
            switch result {
            case .success(let url):
                do {
                    try TsukaimaPairingFileStore.importFile(from: url)
                    message = nil
                } catch {
                    message = "取り込めませんでした"
                }
            case .failure:
                message = "取り込めませんでした"
            }
        }
    }

    /// SideStore の書き出し口を開く。SideStore が `tsukaima-rec://pairingFile?data=…` で返してきたら
    /// AppRouter → TsukaimaPairingFileStore.importIfPairingCallback が保存し、didChange で表示が更新される。
    private func importFromSideStore() {
        guard let url = TsukaimaPairingFileStore.sideStoreExportURL else { return }
        message = nil
        router.pairingFileImportSucceeded = nil
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            message = "SideStore が見つかりません(未インストールか、この版は書き出しに未対応)。ファイルから取り込んでください。"
        }
    }
}
