import SwiftUI

/// この端末の接続のしかた。登録ボタン本体(Tailscale 上での合鍵の受け取り・Secure Enclave 鍵)は
/// 基盤側の 使い魔タブ →「端末」にあるので、ここでは今の状態と場所だけ案内する。
struct SettingsPairingSlot: View {
    var body: some View {
        Section {
            if TsukaimaAPI.shared.isPaired {
                Label("登録済み(自宅の外でも api.yusukedoi.com 経由で使えます)", systemImage: "checkmark.shield")
            } else {
                Label("未登録(Tailscale 接続中だけ使えます)", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("この端末")
        } footer: {
            Text("登録・解除は 使い魔タブ →「端末」から。登録は Tailscale 接続中に 1 回だけ行います。")
        }
    }
}
