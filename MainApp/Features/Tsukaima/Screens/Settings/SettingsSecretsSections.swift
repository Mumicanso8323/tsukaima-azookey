import SwiftUI

// 設定のうち、ログイン情報・カードを扱う欄。どれも Face ID のステップアップつき(stepup: true)。
// 入力した値は送信後すぐに欄から消し、画面・ログには出さない(hub も値そのものは返さない)。

private struct CSInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

private extension View {
    func csPlainInput() -> some View { modifier(CSInputStyle()) }
}

// ---------- iCloud カレンダー ----------
struct SettingsICloudSection: View {
    let configured: Bool
    @State private var appleID = "doiyusuke@icloud.com"
    @State private var appPassword = ""
    @State private var busy = false
    @State private var msg: String?

    var body: some View {
        Section {
            if configured { Label("連携済み(入れ直す場合は下に入力)", systemImage: "checkmark") }
            TextField("Apple ID", text: $appleID)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .csPlainInput()
            SecureField("App 用パスワード(xxxx-xxxx-xxxx-xxxx)", text: $appPassword)
                .csPlainInput()
            Button(busy ? "確認中…" : "保存して読み込む") { Task { await save() } }
                .disabled(busy || appleID.isEmpty || appPassword.isEmpty)
            if let msg { Text(msg).font(.footnote) }
        } header: {
            Text("iCloud カレンダー(手入力の予定を読む)")
        } footer: {
            Text("App 用パスワードは account.apple.com →「サインインとセキュリティ」→「App 用パスワード」で作成。読み取りにだけ使います。")
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let body: [String: Any] = ["apple_id": appleID, "app_password": appPassword]
        appPassword = ""
        do {
            let r = try await CSNet.send("POST", "/api/icloud", json: body, stepup: true, as: SettingsICloudResult.self)
            msg = "✓ \(r.calendars?.count ?? 0) 個のカレンダーから \(r.events ?? 0) 件を読み込みました"
        } catch {
            msg = CSNet.message(error)
        }
    }
}

// ---------- Classroom 用ログイン(大学 Google) ----------
struct SettingsGAuthSection: View {
    let password: Bool
    let totp: Bool
    @State private var pw = ""
    @State private var key = ""
    @State private var busy = false
    @State private var msg: String?

    var body: some View {
        Section {
            Text("\(password ? "パスワード ✓" : "パスワード 未設定") ・ \(totp ? "認証コード鍵 ✓" : "認証コード鍵 未設定")")
                .font(.footnote)
            SecureField("大学 Google のパスワード", text: $pw).csPlainInput()
            SecureField("認証システム アプリの鍵(「スキャンできない場合」に出る英数字)", text: $key).csPlainInput()
            HStack {
                Button("保存") { Task { await save() } }
                    .disabled(busy || (pw.isEmpty && key.isEmpty))
                Spacer()
                Button("今のコードを表示") { Task { await showCode() } }
                    .disabled(busy)
            }
            .buttonStyle(.borderless)
            if let msg { Text(msg).font(.footnote) }
        } header: {
            Text("Classroom 用ログイン(大学 Google)")
        } footer: {
            Text("使い魔が hub の Chrome で Classroom を開くためのログイン情報。hub の外には出しません。Google アカウント → セキュリティ → 2 段階認証プロセス → 認証システム →「QR コードをスキャンできない場合」の鍵を貼り、表示された 6 桁を Google 側に入力。")
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let body: [String: Any] = ["password": pw, "secret": key]
        pw = ""; key = ""
        msg = "保存中…"
        do {
            let r = try await CSNet.send("POST", "/api/gauth", json: body, stepup: true, as: SettingsGAuthCode.self)
            msg = r.code.map { "✓ 保存。Google 側の確認欄にこの 6 桁: \($0)" } ?? "✓ 保存しました"
        } catch {
            msg = CSNet.message(error)
        }
    }

    private func showCode() async {
        busy = true
        defer { busy = false }
        do {
            let r = try await CSNet.send("GET", "/api/gauth/code", stepup: true, as: SettingsGAuthCode.self)
            msg = "今のコード: \(r.code ?? "")(あと \(r.left ?? 0) 秒)"
        } catch {
            msg = CSNet.message(error, fallback: "未設定")
        }
    }
}

// ---------- ログイン情報の金庫 ----------
struct SettingsVaultSection: View {
    var autoHideSeconds: Double = 30
    @State private var reveal: SettingsVaultSite?
    @State private var sites: [SettingsVaultSite]?
    @State private var site = ""
    @State private var login = ""
    @State private var pw = ""
    @State private var totp = ""
    @State private var busy = false
    @State private var msg: String?
    @State private var confirmDelete: SettingsVaultSite?
    @State private var overwriteName: String?

    var body: some View {
        Section {
            if let sites {
                if sites.isEmpty { Text("まだありません").foregroundStyle(.secondary) }
                ForEach(sites) { v in
                    HStack {
                        Button { reveal = v } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.site).foregroundStyle(.primary)
                                Text("\(v.login == true ? "ID ✓" : "ID -") ・ \(v.password == true ? "PW ✓" : "PW -") ・ \(v.totp == true ? "2FA ✓" : "2FA -")\((v.history ?? 0) > 0 ? " ・ 履歴 \(v.history ?? 0)" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Section に付けた sheet は行ごとに分配されて開かない(CI の UI テストで確認)ので、行ごとに付ける
                        .sheet(isPresented: Binding(get: { reveal?.site == v.site },
                                                    set: { if !$0, reveal?.site == v.site { reveal = nil } })) {
                            SettingsVaultRevealView(site: v.site, autoHideSeconds: autoHideSeconds)
                        }
                        .accessibilityIdentifier("vault.row.\(v.site)")
                        .accessibilityHint("Face ID で値を表示します")
                        Button("削除", role: .destructive) { confirmDelete = v }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                Button("登録済みのサイトを表示(Face ID)") { Task { await load() } }
                    .disabled(busy)
                    .accessibilityIdentifier("vault.load")
            }
            TextField("サイト名(例: onSMaRT, Amazon)", text: $site).csPlainInput()
                .accessibilityIdentifier("vault.site")
            TextField("ID・メールアドレス(変えないなら空欄)", text: $login).csPlainInput()
            SecureField("パスワード(変えないなら空欄)", text: $pw).csPlainInput()
            SecureField("2 段階認証の鍵(あれば)", text: $totp).csPlainInput()
            Button(busy ? "保存中…" : "保存") { Task { await requestSave() } }
                .disabled(busy || site.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("vault.save")
                // 同じ名前があるときは、上書きする前に確かめる(2026-10-04 に Google を上書きして前の値を失った)
                .confirmationDialog("「\(overwriteName ?? "")」は既に入っています",
                                    isPresented: Binding(get: { overwriteName != nil }, set: { if !$0 { overwriteName = nil } }),
                                    titleVisibility: .visible) {
                    Button("上書きします(前の値は履歴に残ります)", role: .destructive) {
                        overwriteName = nil
                        Task { await save() }
                    }
                    Button("名前を変える") {
                        overwriteName = nil
                        msg = "別の名前にして、もう一度保存してください"
                    }
                }
            if let msg { Text(msg).font(.footnote) }
        } header: {
            Text("ログイン情報の金庫")
        } footer: {
            Text("使い魔がサイトを代わりに操作するためのログイン情報。hub で暗号化して保管し、チャットには出しません。項目を押すと Face ID のあとで本人だけが値を確かめられます。カードは下の「カード」欄へ。")
        }
        .confirmationDialog("\(confirmDelete?.site ?? "") のログイン情報を削除しますか",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let v = confirmDelete { Task { await delete(v.site) } }
            }
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            sites = try await VaultAPI.list()
            msg = nil
        } catch {
            msg = CSNet.message(error, fallback: "読み込めませんでした")
        }
    }

    /// 名前が既にあるか確かめてから保存する。一覧をまだ見ていなければ先に(Face ID で)読む。
    private func requestSave() async {
        let name = site.trimmingCharacters(in: .whitespaces)
        if sites == nil {
            await load()
            if sites == nil { return }  // 読めないなら、上書きかどうか分からないので保存しない(msg に理由)
        }
        if sites?.contains(where: { $0.site == name }) == true {
            overwriteName = name
        } else {
            await save()
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let body: [String: Any] = ["site": site, "login": login, "password": pw, "totp": totp]
        login = ""; pw = ""; totp = ""
        msg = "保存中…"
        do {
            sites = try await VaultAPI.save(body)
            msg = "✓ 保存しました"
        } catch {
            msg = CSNet.message(error)
        }
    }

    private func delete(_ name: String) async {
        busy = true
        defer { busy = false }
        do {
            try await CSNet.fire("DELETE", "/api/vault/\(CSNet.seg(name))", stepup: true)
            sites = try await CSNet.send("GET", "/api/vault", stepup: true, as: [SettingsVaultSite].self)
            msg = nil
        } catch {
            msg = "削除できませんでした: " + CSNet.message(error)
        }
    }
}

// ---------- カード(PIN で保護) ----------
struct SettingsCardSection: View {
    /// nil = まだ見ていない / .some(nil) = 未登録 / .some(info) = 登録済み
    @State private var info: SettingsCardInfo??
    @State private var number = ""
    @State private var exp = ""
    @State private var cvc = ""
    @State private var name = ""
    @State private var pin = ""
    @State private var busy = false
    @State private var msg: String?
    @State private var confirmDelete = false

    var body: some View {
        Section {
            switch info {
            case .none:
                Button("登録状況を表示(Face ID)") { Task { await load() } }
                    .disabled(busy)
            case .some(.none):
                Text("未登録").foregroundStyle(.secondary)
            case .some(.some(let c)):
                Text(verbatim: "登録済み: **** \(c.last4 ?? "")(\(c.exp ?? ""))")
            }
            TextField("カード番号", text: $number)
                .keyboardType(.numberPad)
                .csPlainInput()
            HStack {
                TextField("有効期限 MM/YY", text: $exp)
                    .keyboardType(.numbersAndPunctuation)
                    .csPlainInput()
                SecureField("セキュリティコード", text: $cvc)
                    .keyboardType(.numberPad)
                    .csPlainInput()
            }
            TextField("名義(ローマ字)", text: $name)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            SecureField("PIN(6〜12 桁の数字。忘れたら登録し直し)", text: $pin)
                .keyboardType(.numberPad)
                .csPlainInput()
            HStack {
                Button(busy ? "暗号化して保存中…" : "保存") { Task { await save() } }
                    .disabled(busy || number.isEmpty || pin.isEmpty)
                Spacer()
                Button("削除", role: .destructive) { confirmDelete = true }
                    .disabled(busy)
            }
            .buttonStyle(.borderless)
            if let msg { Text(msg).font(.footnote) }
        } header: {
            Text("カード(PIN で保護)")
        } footer: {
            Text("あなたの PIN から作った鍵で暗号化。PIN は保存しないので、hub 単独では読めません。注文を確定するときに PIN を入れたときだけ使います。5 回間違えると消えます。")
        }
        .confirmationDialog("カード情報を削除しますか", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await delete() } }
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            info = .some(try await CSNet.send("GET", "/api/card", stepup: true, as: SettingsCardInfo?.self))
            msg = nil
        } catch {
            msg = CSNet.message(error, fallback: "読み込めませんでした")
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        // 送ったらすぐ欄を空にする(成功・失敗どちらでも)。値は画面にもログにも出さない
        let body: [String: Any] = ["number": number, "exp": exp, "cvc": cvc, "name": name, "pin": pin]
        number = ""; exp = ""; cvc = ""; name = ""; pin = ""
        msg = "暗号化して保存中…"
        do {
            let c = try await CSNet.send("POST", "/api/card", json: body, stepup: true, as: SettingsCardInfo.self)
            info = .some(c)
            msg = "✓ 保存しました"
        } catch {
            msg = CSNet.message(error)
        }
    }

    private func delete() async {
        busy = true
        defer { busy = false }
        do {
            try await CSNet.fire("DELETE", "/api/card", stepup: true)
            info = .some(nil)
            msg = "削除しました"
        } catch {
            msg = "削除できませんでした: " + CSNet.message(error)
        }
    }
}
