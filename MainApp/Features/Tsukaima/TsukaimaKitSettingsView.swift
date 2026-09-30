import SwiftUI
import UIKit

/// 使い魔キット(録音・目覚まし)のミニ設定: 接続先 hub の表示、プロビジョニング期限の再送、
/// (有効時のみ)ヘルスケア許可ボタン。アプリ全体のバージョン・更新履歴は azooKey 本体の
/// 「設定」タブ側(About)を参照。
struct TsukaimaKitSettingsView: View {
    #if HEALTHKIT
    @State private var healthStatus = "未確認"
    #endif
    @State private var reported = false
    @State private var paired = TsukaimaDeviceAuth.isPaired
    @State private var pairing = false
    @State private var pairMessage: String?
    @State private var pairCode = ""
    @State private var confirmUnpair = false
    @State private var stepupState = TsukaimaDeviceKeys.stepupState

    var body: some View {
        NavigationView {
            Form {
                Section {
                    LabeledContent("接続先", value: paired ? TsukaimaEndpoint.publicHost : TsukaimaEndpoint.tailscaleHost)
                    if paired {
                        LabeledContent("状態", value: "登録済み" + (TsukaimaDeviceAuth.pairedName.map { "(\($0))" } ?? ""))
                        switch stepupState {
                        case .ok:
                            LabeledContent("Face ID 用の鍵", value: "登録済み")
                        case .outdated:
                            Button {
                                Task { await refreshKey() }
                            } label: {
                                HStack {
                                    Text("鍵を更新(Tailscale 接続中に)")
                                    if pairing { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(pairing)
                        case .unregistered:
                            Button {
                                Task { await refreshKey() }
                            } label: {
                                HStack {
                                    Text("Face ID 用の鍵を登録し直す(Tailscale 接続中に)")
                                    if pairing { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(pairing)
                        }
                        Button("登録を解除", role: .destructive) { confirmUnpair = true }
                    } else {
                        TextField("登録コード(別の登録済み端末で表示)", text: $pairCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .disabled(pairing)
                        Button {
                            Task { await pair() }
                        } label: {
                            HStack {
                                Text("この端末を登録")
                                if pairing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(pairing)
                    }
                    if let pairMessage {
                        Text(pairMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("外からの接続")
                } footer: {
                    Text(paired
                         ? "Tailscale につながっていなくても api.yusukedoi.com 経由で使えます。解除してもサーバ側の登録は残るので、使わなくなった端末は設定の端末一覧から取り消してください。"
                         : "Tailscale 接続中、または登録済みの端末で出した登録コードがあればどこからでも登録できます。登録コードは 設定 →「新しい端末を登録する」で出せます。")
                }
                .confirmationDialog("この端末の登録を解除しますか", isPresented: $confirmUnpair, titleVisibility: .visible) {
                    Button("登録を解除", role: .destructive) {
                        TsukaimaDeviceAuth.unpair()
                        TsukaimaAPI.shared.clearElevation()
                        paired = false
                        stepupState = TsukaimaDeviceKeys.stepupState
                        pairMessage = "解除しました。Tailscale 経由に戻ります。"
                    }
                } message: {
                    Text("この端末の合鍵と鍵を消します。もう一度使うには Tailscale につないで登録し直します。")
                }
                Section {
                    NavigationLink("使い魔の Web 画面を開く") {
                        TsukaimaWebPagesView()
                    }
                } footer: {
                    Text("声の聴き比べなど、hub の Web 画面をこのアプリ内(合鍵つき)で開けます。外のブラウザで開くと forbidden になります。")
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
            .onAppear { stepupState = TsukaimaDeviceKeys.stepupState }
        }
    }

    /// Face ID 用の鍵だけを作り直して hub に登録する(合鍵・端末の登録はそのまま)
    private func refreshKey() async {
        pairing = true
        pairMessage = nil
        defer {
            pairing = false
            stepupState = TsukaimaDeviceKeys.stepupState
        }
        do {
            try await TsukaimaDeviceAuth.registerStepupKey()
            TsukaimaAPI.shared.clearElevation()
            pairMessage = "Face ID 用の鍵を登録しました。"
        } catch {
            pairMessage = error.localizedDescription
        }
    }

    private func pair() async {
        pairing = true
        pairMessage = nil
        let code = pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            pairing = false
            paired = TsukaimaDeviceAuth.isPaired
            stepupState = TsukaimaDeviceKeys.stepupState
        }
        do {
            try await TsukaimaDeviceAuth.pair(name: "使い魔アプリ(\(UIDevice.current.model))",
                                              pairCode: code.isEmpty ? nil : code)
            paired = true
            pairCode = ""
            pairMessage = "登録しました。これからは Tailscale なしでも使えます。"
        } catch let e as URLError {
            pairMessage = code.isEmpty
                ? "hub につながりませんでした。Tailscale につないでからもう一度押してください。(\(e.code.rawValue))"
                : "hub につながりませんでした。(\(e.code.rawValue))"
        } catch {
            // 合鍵は保存済みで Face ID 用の鍵だけ失敗した場合は、その案内(「登録し直す」ボタン)をそのまま出す
            pairMessage = TsukaimaDeviceAuth.isPaired ? error.localizedDescription : "登録できませんでした: \(error.localizedDescription)"
        }
    }
}
