import SwiftUI
import UIKit
import UniformTypeIdentifiers

// ---------- この使い魔にアクセスできる端末 ----------
/// 一覧は誰でも見られる(名前・取り消し済みか・Face ID の有無だけ)。取り消しは Face ID のステップアップつき。
struct SettingsDevicesSection: View {
    @State private var devices: [SettingsDevice]?
    @State private var busy = false
    @State private var msg: String?
    @State private var confirmRevoke: SettingsDevice?

    var body: some View {
        Section {
            if let devices {
                if devices.isEmpty { Text("まだありません").foregroundStyle(.secondary) }
                ForEach(devices) { d in
                    HStack {
                        Text(d.name ?? "端末")
                        if d.revoked == true { Text("(取り消し済み)").foregroundStyle(.secondary) }
                        if d.hasWebauthn == true || d.hasNative == true {
                            Image(systemName: "faceid").foregroundStyle(.secondary).accessibilityLabel("Face ID 登録済み")
                        }
                        Spacer()
                        if d.revoked != true {
                            Button("取り消す", role: .destructive) { confirmRevoke = d }
                                .buttonStyle(.borderless)
                                .disabled(busy)
                        }
                    }
                }
            } else {
                ProgressView()
            }
            if let msg { Text(msg).font(.footnote) }
        } header: {
            Text("この使い魔にアクセスできる端末")
        } footer: {
            Text("api.yusukedoi.com(自宅の外)から使うには、あらかじめ端末を登録します。登録・Face ID の設定は Tailscale 接続中(自宅 Wi-Fi や Tailscale アプリがオンの状態)のときだけできます。")
        }
        .confirmationDialog("「\(confirmRevoke?.name ?? "")」を取り消しますか",
                            isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
                            titleVisibility: .visible) {
            Button("取り消す", role: .destructive) {
                if let d = confirmRevoke { Task { await revoke(d.id) } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            devices = try await CSNet.get("/api/devices", as: SettingsDeviceList.self).devices
        } catch {
            devices = devices ?? []
            msg = "読み込めませんでした: " + CSNet.message(error)
        }
    }

    private func revoke(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            try await CSNet.fire("POST", "/api/devices/\(CSNet.seg(id))/revoke", stepup: true)
            msg = nil
            await load()
        } catch {
            msg = "取り消せませんでした: " + CSNet.message(error)
        }
    }
}

// ---------- iPhone ショートカット用の自動化トークン ----------
/// 発行は Tailscale 経由でのみできる(hub 側で拒否される)。値はこの場でクリップボードに入れるだけで、画面には出さない。
struct SettingsAutomationTokenSection: View {
    @State private var issued: Bool?
    @State private var viaTailscale: Bool?
    @State private var busy = false
    @State private var msg: String?
    @State private var confirmIssue = false

    var body: some View {
        Section {
            Text(statusText).font(.footnote).foregroundStyle(.secondary)
            Button(busy ? "発行中…" : "自動化トークンを発行してコピー") { confirmIssue = true }
                .disabled(busy || viaTailscale != true)
            if viaTailscale == false {
                Text("いまは Tailscale を通っていないので発行できません。自宅 Wi-Fi につなぐか Tailscale アプリをオンにしてから、もう一度開いてください。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let msg { Text(msg).font(.footnote) }
        } header: {
            Text("iPhone ショートカット用の自動化トークン")
        } footer: {
            Text("PayPay のスクリーンショット取り込み・Apple Pay の記録・SMS の確認コード転送、これら無人のショートカット専用の鍵。端末の合鍵(端末の登録)とは別物で、発行し直すとショートカット側の値も更新が必要。発行は Tailscale 接続中のときだけできます。")
        }
        .confirmationDialog("発行し直すと、前のトークンは使えなくなります(ショートカット側の設定も更新が必要)。続けますか",
                            isPresented: $confirmIssue, titleVisibility: .visible) {
            Button("発行してコピー") { Task { await issue() } }
        }
        .task { await load() }
    }

    private var statusText: String {
        switch issued {
        case .some(true): return "発行済み(値は表示できません。中身を確かめたいときは発行し直してください)"
        case .some(false): return "未発行"
        case .none: return "確認中…"
        }
    }

    private func load() async {
        if let s = try? await CSNet.get("/api/devices/automation-token", as: SettingsTokenStatus.self) {
            issued = s.issued
        }
        if let w = try? await CSNet.get("/api/whoami", as: SettingsWhoami.self) {
            viaTailscale = w.kind == "tailscale"
        }
    }

    private func issue() async {
        busy = true
        defer { busy = false }
        msg = "発行中…"
        do {
            let r = try await CSNet.send("POST", "/api/devices/automation-token", as: SettingsTokenIssued.self)
            // 他の端末へは渡さず(localOnly)、10 分で消えるようにしてクリップボードへ
            UIPasteboard.general.setItems([[UTType.plainText.identifier: r.token]],
                                          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
            issued = true
            msg = "✓ コピーしました(10 分でクリップボードから消えます。この画面ではもう見られません)"
        } catch {
            msg = "発行に失敗しました: " + CSNet.message(error)
        }
    }
}
