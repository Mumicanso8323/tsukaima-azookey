import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// POST /api/vault/reveal の応答(本人が Face ID で見るための値。保存・ログ出力は絶対にしない)
struct SettingsVaultSecret: Decodable, Sendable, Equatable {
    var site: String
    var login: String
    var password: String
    var totp: String?
    var totpLeft: Int?
    /// 上書き前の値(新しい順・最大 5 件)。変わった項目だけ入っている
    var history: [SettingsVaultHistoryEntry]?
    /// 消した項目(7 日以内)を見ているときだけ入る
    var deletedAt: Int?
}

struct SettingsVaultHistoryEntry: Decodable, Sendable, Equatable {
    var at: Int
    var login: String?
    var password: String?
    var totp: String?
}

/// 値の取得(Face ID つき)を、同じ項目につき同時に 1 本だけにする。
/// 画面が作り直されて `.task` が再実行されても、進行中の取得に相乗りするだけで、新しい Face ID を重ねない。
/// 呼び出し側(画面)が消えて待ちが取り消されても、取得そのものは続く(次に作られた画面が拾う)。
@MainActor
final class VaultRevealCoalescer {
    private var inflight: [String: Task<SettingsVaultSecret, Error>] = [:]

    func run(_ site: String, op: @escaping @MainActor () async throws -> SettingsVaultSecret) async throws -> SettingsVaultSecret {
        let task: Task<SettingsVaultSecret, Error>
        if let running = inflight[site] {
            task = running
        } else {
            task = Task { @MainActor in try await op() }
            inflight[site] = task
            Task { @MainActor [weak self] in
                _ = try? await task.value
                // 後から作られた別の取得を消さないよう、同じ Task のときだけ外す
                if self?.inflight[site] == task { self?.inflight[site] = nil }
            }
        }
        return try await task.value
    }

    /// 本人が画面を閉じたとき・背面に回ったとき: 進行中の取得をやめる(進行中の Face ID の評価自体は止まらない。次の取得は同じ stepUp に相乗りする)
    func cancel(_ site: String) {
        inflight[site]?.cancel()
        inflight[site] = nil
    }

    func isRunning(_ site: String) -> Bool { inflight[site] != nil }
}

/// 値の画面が scenePhase の変化にどう反応するか。Face ID のシステム画面が出ている間は .inactive になるので、
/// .inactive では何もしない(伏せたり閉じたりすると Face ID の最中に画面が作り直されてループする)。
enum VaultScenePolicy {
    static func shouldHideValues(_ phase: ScenePhase) -> Bool { phase == .background }
    static func shouldClose(_ phase: ScenePhase) -> Bool { phase == .background }
}

/// 金庫の API(一覧・値)。`--vault-mock`(UI テスト専用)のときは偽の値を返す。本番では動かない。
@MainActor
enum VaultAPI {
    nonisolated static let isMock = ProcessInfo.processInfo.arguments.contains("--vault-mock")
    static let revealCoalescer = VaultRevealCoalescer()
    /// 実際に値を取りに行った回数(UI テストの試験台が見せる。値ではなく回数だけ)
    static var revealCount = 0
    private static let mockSites = [SettingsVaultSite(site: "fanatical", login: true, password: true, totp: false, history: 1),
                                    SettingsVaultSite(site: "mock-2fa", login: true, password: true, totp: true, history: 0)]

    /// 保存。返りは保存後の一覧
    static func save(_ body: [String: Any]) async throws -> [SettingsVaultSite] {
        if isMock {
            var l = mockSites
            if let n = body["site"] as? String, !l.contains(where: { $0.site == n }) {
                l.append(SettingsVaultSite(site: n, login: false, password: false, totp: false, history: 0))
            }
            return l
        }
        return try await CSNet.send("POST", "/api/vault", json: body, stepup: true, as: SettingsVaultSaved.self).sites
    }

    static func list() async throws -> [SettingsVaultSite] {
        if isMock {
            return mockSites
        }
        return try await CSNet.send("GET", "/api/vault", stepup: true, as: [SettingsVaultSite].self)
    }

    /// 押すたびに Face ID を取り直す(昇格トークンの 5 分キャッシュを使わない)。外からは端末署名も付く。
    /// 同じ項目の取得が進行中なら、それに相乗りする(Face ID を重ねない)。
    static func reveal(_ site: String) async throws -> SettingsVaultSecret {
        try await revealCoalescer.run(site) { try await revealOnce(site) }
    }

    static func cancelReveal(_ site: String) { revealCoalescer.cancel(site) }

    private static func revealOnce(_ site: String) async throws -> SettingsVaultSecret {
        revealCount += 1
        if isMock {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return SettingsVaultSecret(site: site, login: "mock-user@example.invalid", password: "MOCK-pw-0000-fake",
                                       totp: site == "mock-2fa" ? "123456" : nil, totpLeft: 20,
                                       history: site == "fanatical"
                                           ? [SettingsVaultHistoryEntry(at: 1_790_000_000, login: nil, password: "MOCK-old-pw-1111", totp: nil)] : [])
        }
        await TsukaimaAPI.shared.clearElevation()
        return try await CSNet.send("POST", "/api/vault/reveal", json: ["site": site], signed: true, stepup: true,
                                    as: SettingsVaultSecret.self)
    }
}

/// クリップボードへの書き出し: この端末だけ(Handoff・ユニバーサルクリップボードに流さない)・60 秒で消える
enum VaultClipboard {
    static let expireSeconds: TimeInterval = 60

    static func options(now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        [.localOnly: true, .expirationDate: now.addingTimeInterval(expireSeconds)]
    }

    static func copy(_ s: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: s]], options: options())
    }
}

/// 伏せ字(長さを漏らさないよう固定長)
enum VaultMask {
    static let text = String(repeating: "•", count: 8)
}

/// 項目を押した → Face ID → 値を表示する画面。パスワード・2FA・履歴のパスワードは最初は伏せ字、目のボタンで表示、
/// 30 秒かアプリが背面に回ったら伏せる。
struct SettingsVaultRevealView: View {
    let site: String
    var autoHideSeconds: Double = 30
    var fetch: (String) async throws -> SettingsVaultSecret = VaultAPI.reveal

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var secret: SettingsVaultSecret?
    @State private var error: String?
    @State private var revealed = false

    var body: some View {
        NavigationStack {
            Form {
                if let secret {
                    Section("ID・メールアドレス") {
                        row(id: "login", text: secret.login.isEmpty ? "(未登録)" : secret.login, copyValue: secret.login)
                    }
                    Section("パスワード") {
                        row(id: "password", text: shown(secret.password), copyValue: secret.password, showEye: true)
                    }
                    if let code = secret.totp {
                        Section("2 段階認証の 6 桁(あと \(secret.totpLeft ?? 0) 秒で切り替わる目安)") {
                            row(id: "totp", text: shown(code), copyValue: code)
                        }
                    }
                    if let hist = secret.history, !hist.isEmpty {
                        Section("以前の値(上書きされる前・新しい順)") {
                            ForEach(Array(hist.enumerated()), id: \.offset) { i, h in
                                Text(Self.dateText(h.at)).font(.caption).foregroundStyle(.secondary)
                                if let v = h.login { row(id: "history.\(i).login", text: v, copyValue: v) }
                                if let v = h.password { row(id: "history.\(i).password", text: shown(v), copyValue: v) }
                                if let v = h.totp { row(id: "history.\(i).totp", text: shown(v), copyValue: v) }
                            }
                        }
                    }
                    if let at = secret.deletedAt {
                        Section { Text("この項目は \(Self.dateText(at)) に消しました(消してから 7 日だけ見られます)").font(.footnote) }
                    }
                    Section {
                        Text("コピーした内容は 60 秒で消え、この端末の外には渡りません。表示は 30 秒かアプリを離れると伏せます。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let error {
                    Section {
                        Text(error).accessibilityIdentifier("vault.error")
                        Button("もう一度(Face ID)") { Task { await load() } }
                            .accessibilityIdentifier("vault.retry")
                    }
                } else {
                    Section { HStack { ProgressView(); Text("Face ID で確認中…") } }
                }
            }
            .navigationTitle(site)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { VaultAPI.cancelReveal(site); dismiss() }.accessibilityIdentifier("vault.close")
                }
            }
        }
        .privacySensitive()
        .task { await load() }
        .task(id: revealed) {
            guard revealed else { return }
            try? await Task.sleep(nanoseconds: UInt64(autoHideSeconds * 1_000_000_000))
            if !Task.isCancelled { revealed = false }
        }
        .onChange(of: scenePhase) { _, phase in
            // .inactive(Face ID のシステム画面が出ている間もこうなる)では何もしない。背面に回ったときだけ閉じる
            if VaultScenePolicy.shouldHideValues(phase) { revealed = false }
            if VaultScenePolicy.shouldClose(phase) {  // 戻ったら Face ID からやり直す
                VaultAPI.cancelReveal(site)
                secret = nil
                dismiss()
            }
        }
        .onDisappear { revealed = false; secret = nil }
    }

    private static func dateText(_ unix: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    private func shown(_ s: String) -> String { revealed ? s : VaultMask.text }

    private func row(id: String, text: String, copyValue: String, showEye: Bool = false) -> some View {
        HStack {
            Text(verbatim: text)
                .font(.body.monospaced())
                .textSelection(.disabled)
                .accessibilityIdentifier("vault.\(id).value")
            Spacer()
            if showEye {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealed ? "パスワードを伏せる" : "パスワードを表示")
                .accessibilityIdentifier("vault.eye")
            }
            Button { VaultClipboard.copy(copyValue) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .disabled(copyValue.isEmpty)
                .accessibilityLabel("コピー")
                .accessibilityIdentifier("vault.\(id).copy")
        }
    }

    /// Face ID を取り消されたり失敗したりしても自動ではやり直さない(「もう一度」を押したときだけ)。
    private func load() async {
        guard secret == nil else { return }  // 作り直されて .task が再実行されても、取れている値のために Face ID を出さない
        error = nil
        do {
            let s = try await fetch(site)
            if !Task.isCancelled { secret = s }
        } catch {
            if Task.isCancelled || error is CancellationError { return }  // 画面側の取り消し。エラー扱いにしない
            self.error = CSNet.message(error, fallback: "読み込めませんでした")
        }
    }
}

/// UI テスト専用の試験台(起動引数 `--vault-mock`)。本番では出ない。
/// 値の画面は SettingsScreen と同じく、Form の外側(ここ)に sheet(item:) を 1 つだけ置く。
struct VaultMockHarness: View {
    nonisolated static let isActive = VaultAPI.isMock
    @State private var reveal: SettingsVaultSite?
    @State private var tick = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text("取得 \(VaultAPI.revealCount) 回").accessibilityIdentifier("vault.mock.count")
                    }
                    // 親の再描画・行の作り直しで値の画面が重ならないことの再現用
                    Button("再描画") { tick += 1 }.accessibilityIdentifier("vault.mock.rerender")
                }
                SettingsVaultSection(reveal: $reveal, autoHideSeconds: 3).id(tick)
            }
            .scrollDismissesKeyboard(.immediately)
            .vaultRevealSheet($reveal, autoHideSeconds: 3)
            // 取得の最中(試験台は約 1.5 秒)に親を作り直す。実機で Face ID の前後に起きる再描画の再現
            .onChange(of: reveal) { _, new in
                guard new != nil else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    tick += 1
                }
            }
        }
    }
}

extension View {
    /// 値の画面を 1 か所だけに付ける(行ごとに付けると行の作り直しで複数できる。Section に付けると開かない)
    func vaultRevealSheet(_ item: Binding<SettingsVaultSite?>, autoHideSeconds: Double = 30) -> some View {
        sheet(item: item) { v in
            SettingsVaultRevealView(site: v.site, autoHideSeconds: autoHideSeconds)
        }
    }
}
