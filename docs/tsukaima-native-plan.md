# 使い魔ネイティブ一本化(2026-09-28(月) 夜、今日中に全部)

本人の決定(9/28 昼): SideStore の「使い魔」アプリに全部移す。Web 版(PWA)は通知専用。外は api.yusukedoi.com + 端末の合鍵で Tailscale 不要。
本人(9/28 19:45): 「今日中にすべて解決してほしい。段階踏まなくていい。君が忘れるから」→ Web タブで逃げず、全画面をネイティブ(SwiftUI)にする。

## 分担(repo ~/src/tsukaima-azookey、merge-kit。Xcode は同期フォルダなので新規ファイルは自動で入る)
- 基盤(foundation): Net/TsukaimaAPI.swift(下の契約)、Keychain 合鍵、Secure Enclave 鍵、ペアリング(ts.net で 1 回)、Face ID ステップアップ、署名、TsukaimaConfig の api.yusukedoi.com 化、録音/Intents の Bearer 化、タブ配線(今日/勉強/生活/使い魔/設定 + 既存の録音)。
- 画面 A: Screens/Today(今日タブ + お知らせ/メール/講義の詳細)
- 画面 B: Screens/Study と Screens/Life(勉強・生活タブ: 食事/体重/健康/出費/分割/買い物/注文/イヤホン/睡眠/持ち物)
- 画面 C: Screens/Chat と Screens/Settings(使い魔チャット /api/main/*・inbox、設定: 保管庫/カード/端末/目覚まし/自動化トークン)
- 各画面は新規ファイルのみ。struct TodayScreen/StudyScreen/LifeScreen/ChatScreen/SettingsScreen: View。

## API 契約(基盤が実装、画面はこれだけを使う)
TsukaimaAPI.shared:
- get<T: Decodable>(_ path, query: [String:String] = [:]) async throws -> T
- getJSON(_ path, query:) async throws -> Any
- send<T: Decodable>(_ method, _ path, json: Any? = nil, signed: Bool = false, stepup: Bool = false) async throws -> T
- sendJSON(_ method, _ path, json: Any? = nil, signed: Bool = false, stepup: Bool = false) async throws -> Any
- upload(_ path, data: Data, filename: String, mime: String, fields: [String:String] = [:]) async throws -> Any
- var isPaired: Bool
TsukaimaAPIError: http(Int, String) / notPaired / stepupCancelled / decoding(Error) / transport(Error)
signed: X-Tsukaima-Ts/Sig(/api/main/* 系)。stepup: Face ID → /api/stepup/native → X-Elevation-Token(5 分キャッシュ)。

## 仕上げ
CI(build.yml, merge-kit)緑 → relay:codex-review → IPA を ~/portal-bot/data/dist へ → 本人に更新手順。
