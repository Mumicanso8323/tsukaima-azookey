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
2. **Secure Enclave 鍵**(`TsukaimaDeviceKeys.swift`)
   - 署名鍵(Face ID なし, `.privateKeyUsage`, WhenUnlockedThisDeviceOnly)= `/api/main/*` 等の端末署名用。公開鍵は pair 時に `sign_public_key` として送る。
   - ステップアップ鍵(`.privateKeyUsage + .userPresence`)= `/api/stepup/native` 用。署名のたびに Face ID(失敗時はパスコード)。
   - 鍵本体は SE の暗号化 blob(`dataRepresentation`)を Keychain に保存。
   - 公開鍵は `publicKey.derRepresentation`(SPKI DER)を base64url。署名は `rawRepresentation`(r‖s)を low-S に正規化して base64url。
3. **設定 UI**(`TsukaimaKitSettingsView` に「外からの接続」セクション)
   - 「この端末を登録(Tailscale 接続中に 1 回だけ)」→ 鍵 2 本を作り、ts.net に pair → 同じトークンで native-key 登録 → Keychain に保存。
   - 登録済み表示・接続先表示。「登録を解除」で Keychain のトークン・鍵・WebView の Cookie を消す(サーバ側の取り消しは Web 版の端末一覧から)。
4. **Web タブ**(`TsukaimaWebView.swift`)
   - 使い魔タブのセグメントに「Web」を追加。`https://api.yusukedoi.com/` を WKWebView で開く。
   - 読み込み前に `device_token` Cookie(secure・HttpOnly・domain api.yusukedoi.com・path /・SameSite=Strict)を WebView のデータストアに入れる。
   - JS ブリッジ `window.webkit.messageHandlers.tsukaimaNative`(下記の契約)。この WebView 以外にはブリッジを付けない。
   - `alert`/`confirm`/`prompt` はネイティブのダイアログで出す(PWA が使っている)。
5. **App Intents**: `TsukaimaHub`/`TsukaimaNet` 経由なので自動的に新しい接続先 + Bearer(自動化専用経路を除く)。

## ブリッジの安全要件(必須)
- **ナビゲーション許可リスト**: `https://api.yusukedoi.com`(ホスト完全一致・既定ポート)だけ。それ以外(リダイレクト・`target=_blank`・
  `window.open`・他ホストの iframe)はすべてキャンセル。メインフレームの遷移と新規ウィンドウは http(s) なら**システムのブラウザ**で開き、
  ブリッジ付き WebView には絶対に読み込まない。
- WebKit のメッセージハンドラはフレーム単位で登録できないため、**ハンドラ内で毎回** `message.frameInfo.isMainFrame` と
  `securityOrigin`(`https`・`api.yusukedoi.com`・port 0/443)を確認し、外れたら拒否。加えて上の許可リストで他オリジンのフレーム自体を読ませない。
  ハンドラは `.page` の content world に登録。
- `sign` はネイティブ側が正規化文字列を**自分で組み立てる**(呼び出し側の文字列には署名しない)。時刻は端末の時計。
- `stepup` は毎回 Face ID(ステップアップ鍵の `.userPresence`、再利用猶予 0 の新しい `LAContext`)。

## ブリッジのメッセージ契約(Web 側は後日これに合わせる。portal-bot は今回触らない)
呼び出し: `const r = await window.webkit.messageHandlers.tsukaimaNative.postMessage(msg)`(Promise を返す。失敗時は reject、`Error.message` に理由)。

| `msg` | 戻り値 | 備考 |
|---|---|---|
| `{type:"ping"}` | `{ok:true, paired:bool, version:1}` | ブリッジ有無の判定用 |
| `{type:"sign", method, path, bodySha256Hex}` | `{ts:"<unix秒>", sig:"<base64url r‖s low-S>"}` | `method` は GET/POST/PUT/PATCH/DELETE、`path` は `/api/` で始まり `?`・`#`・改行・空白を含まない、`bodySha256Hex` は小文字 64 桁(本文なしなら空文字列の SHA-256 `e3b0c442…b855`)。Web 側はそのまま `x-tsukaima-ts` / `x-tsukaima-sig` ヘッダに入れる |
| `{type:"stepup"}` | `{elevation_token, expires_in}` | ネイティブが challenge → Face ID 署名 → `/api/stepup/native` を実行。Web 側は `x-elevation-token` ヘッダに入れる |

エラー文字列: `not_allowed`(フレーム/オリジン違反)・`not_paired`・`bad_request`・`cancelled`(Face ID 取り消し)・`server_<status>`・`failed`。

Web 側の採用方針(後日): `window.webkit?.messageHandlers?.tsukaimaNative` があれば、`signMainRequest` を `sign`、WebAuthn のステップアップを `stepup` に置き換える
(署名鍵がネイティブの Secure Enclave 鍵になるので、pair 時の `sign_public_key` と一致する)。

## 変更しないもの
録音(バッファ・再接続)・目覚まし・バックアップ・キーボード・アイコンの CI(`TSUKAIMA_ICON_B64_*`)。サーバの認証ロジック。

## 検証
CI(`build.yml` を `merge-kit` で実行)でビルド成功 → prerelease `merge-test` の ipa を `~/portal-bot/data/dist/tsukaima-azookey.ipa` に原子的に置き換え。
実機確認はオーナーが行う(手順は完了報告に記載)。
