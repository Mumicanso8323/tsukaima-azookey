import SwiftUI
import UIKit

/// ホーム画面のアイコン配置: 読み取り → 配置案(hub / 手貼り JSON)→ 差分の確認 → 適用 → 元に戻す。
/// 端末との通信は全部 `TsukaimaIdeviceBridge`(同期・ブロッキング)なので `Task.detached` で回し、
/// 画面には Sendable な結果(`TsukaimaIconState` / 差分の行)だけを戻す。
struct TsukaimaSpringboardLayoutView: View {
    /// hub 側の受け口(docs/tsukaima-springboard-icon-integration.md §8)。無ければ 404 → 手貼りを案内。
    static let proposalPath = "/api/springboard/proposal"
    static let currentPath = "/api/springboard/current"

    @State private var vpnOn = TsukaimaIdeviceBridge.isVPNInterfacePresent()
    @State private var hasPairingFile = TsukaimaPairingFileStore.exists
    @State private var current: TsukaimaIconState?
    @State private var proposalJSON = ""
    @State private var proposalNote: String?
    @State private var preview: TsukaimaIconApplyResult?
    @State private var latestBackup = TsukaimaIconStateBackupStore.latest
    @State private var busy: String?          // 進行中の説明文(nil なら待機)
    @State private var message: String?       // 結果・エラー
    @State private var messageIsError = false
    @State private var confirmApply = false
    @State private var confirmRestore = false
    @State private var showPaste = false

    var body: some View {
        Form {
            statusSection
            currentSection
            proposalSection
            if let preview { diffSection(preview) }
            restoreSection
            if let busy {
                Section { HStack { ProgressView(); Text(busy).foregroundStyle(.secondary) } }
            }
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(messageIsError ? Color.red : Color.secondary) }
            }
        }
        .navigationTitle("ホーム画面の配置")
        .onAppear { refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: TsukaimaPairingFileStore.didChange)) { _ in refreshStatus() }
        .sheet(isPresented: $showPaste) { pasteSheet }
        .alert("この配置を適用しますか?", isPresented: $confirmApply) {
            Button("適用する", role: .destructive) { Task { await apply() } }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("適用前の配置は端末内に保存され、「元に戻す」で戻せます。アプリ \(preview?.changedAppCount ?? 0) 個の場所が変わります。")
        }
        .alert("適用前の配置に戻しますか?", isPresented: $confirmRestore) {
            Button("元に戻す", role: .destructive) { Task { await restore() } }
            Button("やめる", role: .cancel) {}
        } message: {
            if let latestBackup {
                Text("\(Self.dateLabel(latestBackup.date)) に保存した配置に戻します。")
            }
        }
    }

    // MARK: 各セクション

    private var statusSection: some View {
        Section {
            HStack {
                Text("端末内 VPN(StosVPN)")
                Spacer()
                Text(vpnOn ? "接続中" : "OFF").foregroundStyle(vpnOn ? Color.green : Color.red)
            }
            if !vpnOn {
                // StosVPN には URL スキームが無い(Info.plist に CFBundleURLSchemes 無し)ので、開く導線は作れない。
                Text("StosVPN(または LocalDevVPN)をホーム画面から開いて接続してから、この画面に戻ってください。SideStore で使っているものと同じです。iOS の設定 › VPN からも ON にできます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Text("ペアリングファイル")
                Spacer()
                Text(hasPairingFile ? "取り込み済み" : "未取り込み").foregroundStyle(hasPairingFile ? Color.secondary : Color.red)
            }
        } header: {
            Text("前提")
        } footer: {
            Text("Wi-Fi も PC も要りません。端末内 VPN 経由でこの iPhone 自身の lockdownd(10.7.0.1)に繋ぎます。ペアリングファイルは設定の「ホーム画面の配置」から取り込みます。")
        }
    }

    private var currentSection: some View {
        Section {
            Button("現在の配置を読み取る") { Task { await readCurrent() } }
                .disabled(!ready)
            if let current {
                HStack { Text("ページ数"); Spacer(); Text("\(current.pageCount)").foregroundStyle(.secondary) }
                HStack { Text("Dock"); Spacer(); Text("\(current.dockAppCount) 個").foregroundStyle(.secondary) }
                HStack { Text("アプリ数"); Spacer(); Text("\(current.allAppIDs().count)").foregroundStyle(.secondary) }
                if current.pages.isEmpty || current.pageCount == 0 {
                    Text("iconLists が見つかりません(キー: \(current.topLevelKeys.joined(separator: ", ")))。実機確認 2 を参照。")
                        .font(.footnote).foregroundStyle(.red)
                }
                Button("現在の配置を hub に送る") { Task { await uploadCurrent(current) } }
                    .disabled(busy != nil)
                Button("現在の配置を JSON でコピー") {
                    UIPasteboard.general.string = Self.prettyJSON(TsukaimaIconLayout.exportJSON(current))
                    show("コピーしました", error: false)
                }
            }
        } header: {
            Text("現在の配置")
        }
    }

    private var proposalSection: some View {
        Section {
            Button("hub から配置案を受け取る") { Task { await fetchProposal() } }
                .disabled(current == nil || busy != nil)
            Button("配置案の JSON を貼り付ける") { showPaste = true }
                .disabled(current == nil || busy != nil)
            if let proposalNote {
                Text(proposalNote).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("配置案")
        } footer: {
            Text(current == nil ? "先に「現在の配置を読み取る」を押してください(差分を出すのに要ります)。" : "受け取った配置案は現在の配置と突き合わせて、変わる点を下に並べます。ここではまだ端末に書き込みません。")
        }
    }

    private func diffSection(_ result: TsukaimaIconApplyResult) -> some View {
        Section {
            HStack { Text("場所が変わるアプリ"); Spacer(); Text("\(result.changedAppCount) 個").foregroundStyle(.secondary) }
            HStack { Text("適用後のページ数"); Spacer(); Text("\(result.newState.pageCount)").foregroundStyle(.secondary) }
            if result.diff.isEmpty {
                Text("今の配置と同じです").foregroundStyle(.secondary)
            }
            ForEach(result.diff) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Self.icon(for: line.kind)).foregroundStyle(Self.color(for: line.kind))
                    Text(line.text).font(.footnote)
                }
            }
            Button("この配置を適用する") { confirmApply = true }
                .disabled(!ready || (result.changedAppCount == 0 && result.diff.isEmpty))
        } header: {
            Text("差分")
        }
    }

    private var restoreSection: some View {
        Section {
            if let latestBackup {
                HStack { Text("適用前の配置"); Spacer(); Text(Self.dateLabel(latestBackup.date)).foregroundStyle(.secondary) }
                Button("元に戻す") { confirmRestore = true }
                    .disabled(!ready)
            } else {
                Text("まだ適用していません(保存された配置はありません)").foregroundStyle(.secondary)
            }
        } header: {
            Text("元に戻す")
        } footer: {
            Text("適用のたびに、その直前の配置を端末内に保存します(直近 \(TsukaimaIconStateBackupStore.keepCount) 件)。")
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("docs の §8 の形式(version / dock / pages)の JSON を貼り付けてください。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $proposalJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
            }
            .padding()
            .navigationTitle("配置案を貼り付け")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showPaste = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("差分を見る") {
                        showPaste = false
                        buildPreview(from: Data(proposalJSON.utf8), note: "手貼りの配置案")
                    }
                    .disabled(proposalJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: 状態

    private var ready: Bool { vpnOn && hasPairingFile && busy == nil }

    private func refreshStatus() {
        vpnOn = TsukaimaIdeviceBridge.isVPNInterfacePresent()
        hasPairingFile = TsukaimaPairingFileStore.exists
        latestBackup = TsukaimaIconStateBackupStore.latest
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    // MARK: 端末との通信

    private func readCurrent() async {
        guard let data = TsukaimaPairingFileStore.load() else { show(TsukaimaIdeviceError.pairingFileMissing.localizedDescription, error: true); return }
        busy = "読み取り中…(10.7.0.1:62078)"
        message = nil
        defer { busy = nil }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try TsukaimaIdeviceBridge.readIconState(pairingFileData: data) }
        }.value
        switch result {
        case .success(let state):
            current = state
            preview = nil
            show("読み取りました(\(state.pageCount) ページ・アプリ \(state.allAppIDs().count) 個)", error: false)
        case .failure(let error):
            show(Self.describe(error), error: true)
        }
    }

    private func uploadCurrent(_ state: TsukaimaIconState) async {
        busy = "hub に送信中…"
        defer { busy = nil }
        do {
            _ = try await TsukaimaAPI.shared.sendJSON("POST", Self.currentPath, json: TsukaimaIconLayout.exportJSON(state))
            show("現在の配置を hub に送りました", error: false)
        } catch {
            show(Self.describe(error), error: true)
        }
    }

    private func fetchProposal() async {
        busy = "hub から受け取り中…"
        defer { busy = nil }
        do {
            let obj = try await TsukaimaAPI.shared.getJSON(Self.proposalPath)
            let data = try JSONSerialization.data(withJSONObject: obj)
            let note = (obj as? [String: Any])?["note"] as? String
            buildPreview(from: data, note: note ?? "hub の配置案")
        } catch TsukaimaAPIError.http(let status, _) where status == 404 {
            show("hub にまだ配置案がありません(\(Self.proposalPath) が 404)。JSON を貼り付ける方法も使えます。", error: true)
        } catch {
            show(Self.describe(error), error: true)
        }
    }

    private func buildPreview(from json: Data, note: String) {
        guard let current else { show("先に現在の配置を読み取ってください", error: true); return }
        do {
            let proposal = try TsukaimaIconProposal.parse(json: json)
            let result = try TsukaimaIconLayout.apply(proposal, to: current.xml)
            preview = result
            proposalNote = proposal.note ?? note
            show(result.diff.isEmpty ? "今の配置と同じです" : "差分を確認して「この配置を適用する」を押してください", error: false)
        } catch {
            preview = nil
            show(Self.describe(error), error: true)
        }
    }

    private func apply() async {
        guard let current, let preview else { return }
        guard let data = TsukaimaPairingFileStore.load() else { show(TsukaimaIdeviceError.pairingFileMissing.localizedDescription, error: true); return }
        busy = "適用中…"
        message = nil
        defer { busy = nil }
        // 適用前の配置を先に保存する(保存できなければ適用しない)
        do {
            try TsukaimaIconStateBackupStore.save(current.xml)
        } catch {
            show("適用前の配置を保存できなかったので中止しました", error: true)
            return
        }
        latestBackup = TsukaimaIconStateBackupStore.latest
        let xml = preview.newState.xml
        let result = await Task.detached(priority: .userInitiated) {
            Result { try TsukaimaIdeviceBridge.writeIconStateXML(xml, pairingFileData: data) }
        }.value
        switch result {
        case .success:
            self.preview = nil
            show("適用しました。ホーム画面で確認してください(反映されていなければ「元に戻す」で戻せます)", error: false)
            await readCurrent()
        case .failure(let error):
            show(Self.describe(error), error: true)
        }
    }

    private func restore() async {
        guard let latestBackup, let xml = TsukaimaIconStateBackupStore.load(latestBackup) else {
            show("保存された配置を読めませんでした", error: true)
            return
        }
        guard let data = TsukaimaPairingFileStore.load() else { show(TsukaimaIdeviceError.pairingFileMissing.localizedDescription, error: true); return }
        busy = "元に戻しています…"
        message = nil
        defer { busy = nil }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try TsukaimaIdeviceBridge.writeIconStateXML(xml, pairingFileData: data) }
        }.value
        switch result {
        case .success:
            preview = nil
            show("適用前の配置に戻しました", error: false)
            await readCurrent()
        case .failure(let error):
            show(Self.describe(error), error: true)
        }
    }

    // MARK: 表示補助

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "失敗しました"
    }

    private static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) HH:mm"
        return f.string(from: date)
    }

    private static func prettyJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func icon(for kind: TsukaimaIconDiffLine.Kind) -> String {
        switch kind {
        case .moved: "arrow.right"
        case .folderAdded: "folder.badge.plus"
        case .folderRemoved: "folder.badge.minus"
        case .unlisted: "tray.and.arrow.down"
        case .missing: "questionmark.circle"
        case .warning: "exclamationmark.triangle"
        }
    }

    private static func color(for kind: TsukaimaIconDiffLine.Kind) -> Color {
        switch kind {
        case .moved: .blue
        case .folderAdded, .folderRemoved: .orange
        case .unlisted: .secondary
        case .missing: .secondary
        case .warning: .red
        }
    }
}
