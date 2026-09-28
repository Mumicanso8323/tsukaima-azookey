# 使い魔アプリの Tailscale 無し接続(api.yusukedoi.com)— 実装ブリーフ

対象ブランチ: `merge-kit`。サーバ側(`~/portal-bot/bot/web.py`・`bot/deviceauth.py`)の認証は実装済みで、
**このブリーフではサーバを一切変更しない**。サーバの仕様は portal-bot の `docs/public-access-spec.md`。

## ゴール
- ネイティブアプリ「使い魔」を唯一の UI にする。Web 版(PWA)は Web Push の受信専用に残す。
- Tailscale 無しでも `https://api.yusukedoi.com`(Cloudflare Tunnel → `ashwell-hub.taila653da.ts.net` と同じ FastAPI)で動く。

## サーバ側の前提(読んだ結果)
| 項目 | 内容 |
|---|---|
| 識別 | `_resolve_identity`: Tailscale 本人ヘッダ(ts.net Host・cf-* 無し)なら `tailscale`、それ以外は `Authorization: Bearer <token>` か Cookie `device_token` で `device` |
| 登録 | `POST /api/devices/pair`(Tailscale 経由のみ)`{name, sign_public_key}` → `{id,name,token}`。`sign_public_key` は **SPKI DER を base64(url)**(`load_der_public_key` で読む) |
| ネイティブ鍵 | `POST /api/devices/native-key`(Tailscale 経由 **かつ** Bearer 付き)`{public_key: base64(SPKI DER)}` |
| ステップアップ | `GET /api/stepup/challenge`(`device` のみ=api 側)→ `{nonce}`、nonce の UTF-8 を ES256 署名 → `POST /api/stepup/native {nonce, signature}` → `{elevation_token, expires_in:300}`。以後 `x-elevation-token` ヘッダ |
| 端末署名 | `require_main_signature`: ヘッダ `x-tsukaima-ts` / `x-tsukaima-sig`。正規化文字列 `METHOD\nPATH\nTS\nsha256hex(body)`(PATH はクエリ無しの `request.url.path`)。±60 秒、リプレイ拒否 |
| 署名形式 | raw `r‖s` 64 バイトを base64url。**low-S 必須**(`s ≤ n/2`、そうでなければ拒否) |
| 自動化専用経路 | `/api/sms`・`/api/spend/ocr`・`/api/spend/applepay`・`/api/spend/import` は api 側では **Bearer が効かない**(`X-Automation-Token` のみ) |
| WebSocket | `/ws/record` は `_allowed` + `_same_origin`(Origin 無しなら可)。Bearer ヘッダで通る |

## 実装計画(MainApp/Features/Tsukaima)
1. **接続先の切り替え**(`TsukaimaShared/TsukaimaEndpoint.swift` + `TsukaimaConfig`)
   - Keychain に端末トークンがあれば `https://api.yusukedoi.com`、無ければ従来の ts.net。
   - `Authorization: Bearer` は **URL のホストがちょうど api.yusukedoi.com のときだけ**付ける(`TsukaimaEndpoint.authorize`)。
   - `/ws/record`・`/api/device/expiry`・`/api/wake`・`/api/device/log` はすべてこの経路。WebSocket は `URLRequest` にヘッダを載せて `webSocketTask(with: URLRequest)`。
   - 録音の 30 分バッファ(`maxBufferedChunks`)は変更しない。
   - 共有拡張・App Intents が使う `TsukaimaHub`/`TsukaimaNet` も同じ規則。ただし自動化専用経路(applepay・ocr)は
     Bearer が効かないので **従来どおり ts.net 固定**(Tailscale 外で動かすには別途 `X-Automation-Token` 対応が要る。今回は範囲外)。
   - 端末トークンの Keychain 保存は、共有コード(`TsukaimaShared`)から読めるよう `TsukaimaShared/TsukaimaDeviceToken.swift` に置く
     (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`、`kSecClassGenericPassword`)。トークンはログ・画面に一切出さない。
2. **Secure Enclave 鍵**(`Net/TsukaimaDeviceKeys.swift`、登録・署名・ステップアップは `Net/TsukaimaDeviceAuth.swift`)
   - 署名鍵(Face ID なし, `.privateKeyUsage`, WhenUnlockedThisDeviceOnly)= `/api/main/*` 等の端末署名用。公開鍵は pair 時に `sign_public_key` として送る。
   - ステップアップ鍵(`.privateKeyUsage + .userPresence`)= `/api/stepup/native` 用。署名のたびに Face ID(失敗時はパスコード)。
   - 鍵本体は SE の暗号化 blob(`dataRepresentation`)を Keychain に保存。
   - 公開鍵は `publicKey.derRepresentation`(SPKI DER)を base64url。署名は `rawRepresentation`(r‖s)を low-S に正規化して base64url。
3. **登録 UI**(`TsukaimaKitSettingsView` に「外からの接続」セクション)
   - 「この端末を登録(Tailscale 接続中に 1 回だけ)」(使い魔タブ → 端末)→ 鍵 2 本を作り、ts.net に pair → 同じトークンで native-key 登録 → Keychain に保存。
   - 登録済み表示・接続先表示。「登録を解除」で Keychain のトークン・鍵を消す(サーバ側の取り消しは Web 版の端末一覧から)。
4. **画面から使う API**(`Net/TsukaimaAPI.swift`、契約は `docs/tsukaima-native-plan.md`)
   - `TsukaimaAPI.shared` の `get`/`getJSON`/`send`/`sendJSON`/`upload`/`isPaired`。登録済みなら api.yusukedoi.com + Bearer、未登録なら ts.net。
   - `signed: true` で `X-Tsukaima-Ts`/`X-Tsukaima-Sig`(正規化文字列はネイティブ側で組み立てる)、`stepup: true` で Face ID → `X-Elevation-Token`(5 分キャッシュ、`stepup_required` の 401 は 1 回だけ取り直し)。
   - エラーは `TsukaimaAPIError`(`http`/`notPaired`/`stepupCancelled`/`decoding`/`transport`)。
5. **タブ配線**: 下のタブバーを 今日 / 勉強 / 生活 / 使い魔 / 設定 にする。使い魔タブの中は チャット / 録音 / 目覚まし / 端末(登録)。
   設定タブの中は 使い魔(SettingsScreen)/ キーボード(azooKey の 設定・拡張・着せ替え・使い方)。録音エンジンと目覚ましは `AppTabView` が持つ
   (最初に開くタブが「今日」になっても鳴動・復元が止まらないように)。目覚ましが鳴っている/チェック中/セット中は最初から使い魔タブ。
   各画面の本物が入るまでは `Screens/_Placeholders.swift` の仮置き。
6. **App Intents**: `TsukaimaHub`/`TsukaimaNet` 経由なので自動的に新しい接続先 + Bearer(自動化専用経路を除く)。

## 取りやめ: Web タブ(WKWebView)と JS ブリッジ
2026-09-28 夜のオーナー判断で「全画面ネイティブ(SwiftUI)」に変更したため、WKWebView タブと
`tsukaimaNative` ブリッジは作らない。Web 版は Web Push の受信専用。

## 変更しないもの
録音(バッファ・再接続)・目覚まし・バックアップ・キーボード・アイコンの CI(`TSUKAIMA_ICON_B64_*`)。サーバの認証ロジック。

## 検証
CI(`build.yml` を `merge-kit` で実行)でビルド成功 → prerelease `merge-test` の ipa を `~/portal-bot/data/dist/tsukaima-azookey.ipa` に原子的に置き換え。
実機確認はオーナーが行う(手順は完了報告に記載)。
