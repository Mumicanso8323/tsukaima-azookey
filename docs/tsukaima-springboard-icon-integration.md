# ホーム画面アイコン配置の読み書き — 組み込み手順(続き)

前提: [tsukaima-springboard-icon-feasibility.md](tsukaima-springboard-icon-feasibility.md) の続き。
あちらの結論(「Rust の C FFI に `get_icon_state`/`set_icon_state` が無いので実装は止める」)を受けて、
fork してその FFI を追加した。**このファイルはコードを書かない、組み込み手順のドキュメントのみ**。

> **2026-09 更新(springboard-vpn ブランチ)**: 接続方式の確定(§7)・`set_icon_state` の実装と配置案の
> JSON 形式(§8)・実機確認チェックリスト(§9)を追加した。§3 の「ポート未確認」「RSD フォールバック」の
> 記述は §7 で解消済み(62078 で確定、49152 は別物)。§6 の「読み取り専用」も §8 で書き込みまで進んだ。

## 0. 今回やったこと(このドキュメントの前提)

- fork: https://github.com/Mumicanso8323/idevice (public, upstream: `jkcoxson/idevice`)
- 追加した C FFI(`ffi/src/springboardservices.rs`、既存の同ファイルの流儀に完全準拠):
  - `springboard_services_get_icon_state(client, format_version, out_result: *mut plist_t)`
  - `springboard_services_set_icon_state(client, icon_state: plist_t)`
  - `springboard_services_set_icon_state_with_version(client, icon_state: plist_t, format_version)`
  - アイコン画像取得は既存の `springboard_services_get_icon(client, bundle_identifier, out_result, out_result_len)`
    が既にあったので追加不要(フィージビリティ調査時点から変わっていない)。
- テスト: 実機なしで通る範囲(null 引数ガード・不正 UTF-8 の `format_version` 拒否・
  `PlistWrapper` の clone 経路)を `ffi/src/springboardservices.rs` の `#[cfg(test)]` に追加、
  ローカルで `cargo test`/`cargo fmt --check`/`cargo clippy --all-targets --all-features -D warnings`
  (`justfile` の `ci-check` と同じ条件)まで確認済み。
- CI: fork 側に元々ある `.github/workflows/ci.yml`(upstream 由来、変更していない)が macOS ランナーで
  `aarch64-apple-ios`/`aarch64-apple-ios-sim`/`x86_64-apple-ios` 他をビルドし、
  `xcodebuild -create-xcframework` で `swift/IDevice.xcframework` を作って
  `swift/bundle.zip` として Actions アーティファクトに上げる(タグ push 時は GitHub Release にも付く)。
  今回はこれを実行して緑になったことを確認した(実行結果は本人への返信に記載)。

## 1. 成果物の入手方法

配布物は2通り。**タグを打つ方式(B)を推奨**(URL が固定される・90日で消えない)。

### A. Actions アーティファクトから(お試し用、90日で失効)
```
gh run list --repo Mumicanso8323/idevice --limit 5
gh run download <run-id> --repo Mumicanso8323/idevice -n idevice-xcframework -D /tmp/idevice-xc
```
中に `bundle.zip`(= `swift/IDevice.xcframework` を zip したもの)が入っている。

### B. リリースタグを打つ方式(推奨・実施済み)
```
cd ~/src/idevice
git tag v0.1.68-tsukaima1   # upstream のバージョンに接尾辞を付けて衝突回避
git push origin v0.1.68-tsukaima1
```
タグ push 自体では `ci.yml` の `tags: ['v*.*.*']` トリガーが(原因未調査のまま)発火しなかったため、
`gh workflow run ci.yml --ref v0.1.68-tsukaima1` で明示的に workflow_dispatch した
(`github.ref` はタグ参照になるので `release` ジョブの `if: startsWith(github.ref, 'refs/tags/v')` は
そのまま成立する)。これで実際に GitHub Release が作られ、固定 URL で落とせる状態になっている:

https://github.com/Mumicanso8323/idevice/releases/download/v0.1.68-tsukaima1/idevice-xcframework-v0.1.68-tsukaima1.zip

(Release ページ: https://github.com/Mumicanso8323/idevice/releases/tag/v0.1.68-tsukaima1)

どちらでも展開すると `IDevice.xcframework/` 一式(`ios-arm64` / `ios-arm64-simulator` /
`macos-arm64_x86_64` / maccatalyst 用スライスと、共通の `Headers/idevice.h`)が手に入る。

## 2. Xcode への組み込み(直接埋め込み方式、推奨)

`swift/Package.swift` は `plist.xcframework` という**このリポジトリの CI では作られていない**
バイナリターゲットも参照しているため(`justfile` に生成レシピが無い。おそらく別リポジトリ
`plist_ffi` 側の成果物を手動で置く前提の、upstream 側の未整備/手作業依存の記述)、
**SwiftPM 経由でこの `Package.swift` をそのまま使う経路は今回は避ける**。

代わりに、`IDevice.xcframework` だけで完結する直接埋め込み方式を使う:
理由は、`ffi/build.rs` が `plist.h` の内容を `idevice.h` の末尾に連結してから
`swift/include/idevice.h` にコピーしており、かつ `plist_ffi` クレートは
`idevice-ffi` の通常の依存クレートとして**同じ `libidevice_ffi.a` に静的リンクされる**ため
(`ffi/Cargo.toml` の `crate-type = ["staticlib", ...]`)、`plist_new_dict`/`plist_free` などの
plist 生成・解放関数は **`IDevice.xcframework` 単体に既に含まれている**。別の xcframework は不要。

手順:
1. 展開した `IDevice.xcframework` を Xcode プロジェクトにドラッグ&ドロップ
   (ターゲット: 使い魔本体アプリ、"Copy items if needed" は任意、
   "Embed & Sign" ではなく **静的ライブラリなので "Do Not Embed"** でよい)。
2. ターゲットの Build Settings で問題なければ何もしなくてよいが、
   `.a` が複数プラットフォームスライスを含む xcframework なので、
   通常は追加設定不要(Xcode が xcframework から実行環境に合うスライスを自動選択する)。
3. Swift から C 関数を直接呼ぶために、Objective-C/C 用の bridging header か、
   `module.modulemap`(fork の `swift/include/module.modulemap`、中身は
   `module IDevice { header "idevice.h"; export * }`)を使ったモジュールとしての import の
   どちらかが要る。xcframework の Headers に `module.modulemap` を同梱していない場合は
   `swift/include/module.modulemap` を手動で `IDevice.xcframework/ios-arm64/Headers/` などにも
   コピーしておくと `import IDevice` で使える(cbindgen が吐く `idevice.h` は C ヘッダなので、
   モジュールマップが無いと bridging header 経由でしか呼べない)。
   最小構成で急ぐならまず bridging header 経由(`#import "idevice.h"`)で試すのが早い。

## 3. 呼び出しの流れ(Swift 側、擬似コード込み)

fork の `ffi/examples/heartbeat.c` と `ffi/src/provider.rs`/`pairing_file.rs` のソースで
確認した実際のシグネチャと所有権規約に基づく(推測なし)。

```c
// C 側のシグネチャ(idevice.h から抜粋、そのまま)
IdeviceFfiError *idevice_pairing_file_read(const char *path, IdevicePairingFile **pairing_file);
IdeviceFfiError *idevice_tcp_provider_new(const struct sockaddr *ip,
                                           IdevicePairingFile *pairing_file, // 成功時に consume される
                                           const char *label,
                                           IdeviceProviderHandle **provider);
void idevice_provider_free(IdeviceProviderHandle *provider); // connect 後も呼び手が解放する(borrow only)

IdeviceFfiError *springboard_services_connect(IdeviceProviderHandle *provider,
                                               SpringBoardServicesClientHandle **client);
IdeviceFfiError *springboard_services_get_icon_state(SpringBoardServicesClientHandle *client,
                                                      const char *format_version /* NULL 可 */,
                                                      plist_t *out_result);
IdeviceFfiError *springboard_services_set_icon_state(SpringBoardServicesClientHandle *client,
                                                      plist_t icon_state /* clone される、呼び手が解放 */);
void springboard_services_free(SpringBoardServicesClientHandle *client);
void plist_free(plist_t node);
void idevice_error_free(IdeviceFfiError *err);
```

Swift からの呼び出し順(読み取りのみのデモ、計画書のステップ4に対応):

1. LocalDevVPN(既存の SideStore 用 NetworkExtension)が接続中であることを確認する。
2. `Documents/Tsukaima/pairingFile.plist` を `idevice_pairing_file_read` で読む
   (バイト列から読む場合は `idevice_pairing_file_from_bytes`)。**中身をログに一切出さない**
   (エラー時も `err->message` はコード/種別のみで済むよう、path を含めた詳細ログは自前で書かない)。
3. `sockaddr_in` を組み立てて `idevice_tcp_provider_new` に渡す。**ポート番号は §7 で 62078 に確定
   (以下は当時の記録)**: fork の `ffi/src/lib.rs` は `LOCKDOWN_PORT = 62078`(通常の USB/TCP 越し lockdownd の
   ポート、`ffi/examples/heartbeat.c` もこれを使っている)と定義している一方、フィージビリティ
   調査§2で確認した StikJIT の統合ガイドは LocalDevVPN 越しの既定エンドポイントとして
   `10.7.0.1:49152` を明記している。この 49152 が「VPN トンネル自体の待受ポート」なのか
   「lockdownd 宛てのポートフォワード先」なのかは今回のソース調査(idevice 側)だけでは
   確定できなかった(StikJIT 側の LocalDevVPN 実装コードまでは読んでいない)。
   **実装時は両方試す**: まず `62078` で `idevice_tcp_provider_new` を試し、接続エラーになったら
   `49152` で再試行する、程度のフォールバックにしておくのが安全(推測で決め打ちしない)。
   **フィージビリティ調査の§4の通り、iOS バージョンによっては RSD 経由必須の可能性があるため、
   classic 接続が `IdeviceError` を返したら `springboard_services_connect_rsd` へのフォールバックを
   後日実装できるよう関数を分けておく**(今回はフォールバック実装はしない、呼び出し口だけ用意)。
4. `springboard_services_connect(provider, &client)` → 成功したら `idevice_provider_free(provider)`
   (provider は borrow only、連続して複数サービスに使い回せる)。
5. `springboard_services_get_icon_state(client, nil, &out)` → `out`(`plist_t`)を Swift 側の
   モデルに変換。変換には plist_ffi の getter 群(`plist_dict_get_item`/`plist_array_get_size` 等、
   同じ `idevice.h` に同梱)を使うか、一旦 `plist_to_xml`/`plist_to_bin` 相当の関数で
   シリアライズしてから `PropertyListSerialization`(Foundation 標準)でパースする方が
   Swift 側の実装コストは低い(要: fork の `plist.h` で該当関数名を確認してから実装する。
   このドキュメントでは実装しないので未確認のまま)。
6. デバッグ用に「ページ数」「Dock アプリ数」だけ表示して `plist_free(out)` → `springboard_services_free(client)`。
7. `set_icon_state` を呼ぶ場合は、取得した `icon_state` を Swift 側で書き換えてから
   `springboard_services_set_icon_state(client, mutated)` を呼び、呼び手側で `mutated` を
   `plist_free` する(clone されるだけで所有権は移らない、既存の `installation_proxy_install`
   の `options` 引数と同じ規約)。**この最初の実装では読み取りのみに留め、書き込みボタンは
   実装しない**(計画書のステップ4の方針を維持)。

## 4. ペアリング記録の扱い(今回追加分)

フィージビリティ調査§3で「取り込み UI は StikJIT 方式(`UIDocumentPickerViewController` +
security-scoped access + atomic 置き換え)」まで決めてある。追加で決めておくべきこと:

- **保管場所は Keychain ではなくファイル**でよい(StikJIT もファイルベース)。ただし
  `Documents/Tsukaima/pairingFile.plist` は端末バックアップに含まれる点に注意
  (iCloud/iTunes バックアップ経由でこのファイルが漏れる経路になり得る)。
  `NSFileProtectionComplete` 相当の data protection 属性を付けて保存することを推奨
  (実装時に `FileManager` の `.protectionKey` を設定)。
- アプリ内でこのファイルの中身を **文字列化・ログ出力・共有シートへの受け渡しをしない**
  (本人の既存方針、CLAUDE.md にも明記の秘密情報)。エラー表示は「ペアリングに失敗しました」
  程度に留め、plist の中身や生エラーメッセージをそのまま画面に出さない。
- 取り込み後、`idevice_tcp_provider_new` に渡した時点でそのインスタンスは consume される
  (§3 参照)。再接続のたびに `idevice_pairing_file_read` から読み直すか、アプリ側で
  パース済みの `IdevicePairingFile` ハンドルを使い回さず毎回作り直す設計にする
  (このライブラリの所有権規約上、使い回すなら `idevice_pairing_file_serialize` で
  一旦バイト列に戻してから複製する必要があり、素直に毎回ファイルから読み直す方が単純)。

## 5. 未確認・次にやる場合の宿題

- `plist.h` の getter/setter 関数名の確認(上記§3-5)。
- classic lockdown 接続が失敗した場合の RSD フォールバック実装
  (`springboard_services_connect_rsd` は fork でも既存のまま、変更していない)。
- `swift/Package.swift` の `plist.xcframework` 依存を今回の直接埋め込み方式で回避した件は
  upstream の未整備(またはドキュメント不足)の可能性があるため、余裕があれば upstream に
  Issue を立てて確認してもよい(今回は fork 内で完結させたので issue は立てていない)。
- CI のビルド結果(緑になったログ)は本人への返信メッセージに記載。再現・確認したい場合は
  `gh run list --repo Mumicanso8323/idevice` で見られる。

## 6. 組み込み実施ログ(`photos` ブランチ、実機なしで進められる範囲)

実際にダウンロードした `idevice-xcframework-v0.1.68-tsukaima1.zip`(213,929,225 バイト)を展開し、
`ios-arm64/Headers/idevice.h`(11,324 行、libplist.h をそのまま末尾に連結済み)を読んで、
上記「要確認」2点をコードの事実で解消した:

- **lockdown のポート**: ヘッダ自身が 28 行目で `#define LOCKDOWN_PORT 62078` を公開しており、
  `springboard_services` 系関数のシグネチャもこれを前提にしている(examples/heartbeat.c も同じ値)。
  これを第一候補として採用した(`TsukaimaIdeviceBridge.candidatePorts` の先頭)。StikJIT ガイドの
  49152 は用途が別(RSD 系トンネルのエンドポイントの可能性)と見ているが実機で確認していないため、
  フォールバックの第二候補としてだけ残した。**実機確認が必要**: 62078 で繋がらない場合、実際に
  49152 で繋がるか、あるいは classic lockdown 自体が iOS バージョンによっては通らず RSD 必須になるか
  (§4 で触れた通り)。
- **plist の getter/setter**: `idevice.h` の後半(9860行目〜)に libplist.h がそのまま同梱されており、
  `plist_dict_get_item` / `plist_array_get_size` / `plist_get_string_val` / `plist_to_xml` /
  `plist_from_xml` / `plist_free` など標準の libplist API がフルセットで使える(fork 側の
  `ffi/build.rs` が連結している、という元の推測どおりだった)。実装では C の木を自前で辿らず、
  `plist_to_xml` → `PropertyListSerialization`(Foundation)に投げる方式を採用した
  (本ドキュメント§3-5で「実装コストが低い」としていた案)。

組み込んだコード(`MainApp/Features/Tsukaima/Springboard/`):
- `TsukaimaIdeviceBridge.swift`: ペアリングファイル読み込み → TCP provider(port フォールバックつき)
  → `springboard_services_connect` → `get_icon_state` → `plist_to_xml` → `PropertyListSerialization`
  → ページ数(`iconLists`)・Dock アプリ数(`buttonBar`)の要約を返す、読み取り専用のデモ。
  `set_icon_state` は呼んでいない(このドキュメントの元の方針どおり)。
- `TsukaimaPairingFileStore.swift`: `Documents/Tsukaima/pairingFile.plist` への
  `NSFileProtectionComplete` つき atomic 保存・読み込み・削除。中身はログ・画面に一切出さない。
- 設定画面(`SettingsSpringboardSection.swift`、`MainApp/Features/Tsukaima/Screens/Settings/`):
  `.fileImporter`(UIDocumentPickerViewController 相当)でのペアリングファイル取り込みと、
  「ホーム画面を読み取る(実験)」ボタン。並べ替えて適用する機能はまだ無い(疎通確認が先)。
- Xcode 側: `IDevice.xcframework` を `MainApp/Vendor/IDevice.xcframework` として参照する形で
  `azooKey.xcodeproj/project.pbxproj` に直接編集で追加(`azooKey` ターゲットの
  Frameworks ビルドフェーズにリンクのみ・埋め込みなし = 静的ライブラリなので「Do Not Embed」)。
  **`MainApp/Vendor/` は `.gitignore` 済みでリポジトリには入れていない**(展開後の xcframework が
  4スライス合計で約1.3GB、実機(ios-arm64)スライスだけでも約200MBあり、公開リポジトリに直接
  コミットするのは不適切と判断したため)。ビルド前に
  本ドキュメント§1の手順でダウンロードしたzipを展開し、`IDevice.xcframework` を
  `MainApp/Vendor/IDevice.xcframework` に置くこと。
  `module.modulemap` が各スライスの `Headers/` に同梱されているため、bridging header は使わず
  Swift 側は `import IDevice` だけで C 関数・libplist 関数を呼べる(§2で「無ければ手動コピー」と
  書いていた同梱チェックは、実際のダウンロード物で確認した結果「同梱されている」ことがわかった)。

**実機でしかできない確認(次にやる人向け)**:
1. LocalDevVPN 接続中に実際に `TsukaimaIdeviceBridge.readIconStateSummary` が繋がるか
   (62078/49152 のどちらで、あるいはどちらでも繋がらず RSD が要るか)。
2. `get_icon_state` が返す plist のトップレベルキーが本当に `iconLists`/`buttonBar` か
   (未確認のまま採用した libSpringBoard 由来の通称キー名。違えば `TsukaimaIconStateSummary` の
   集計ロジックだけ直せばよい設計にしてある — `topLevelKeys` で実際のキー一覧も取れる)。
3. Xcode でのビルド自体(pbxproj は手編集のため、Xcode で開いて素直に読めるかの確認を含む)。
4. 写真自動バックアップの BGAppRefreshTask が実機でどの程度の頻度で起きるか(iOS の裁量なので
   確実性は無い前提。「アプリを開いたとき」が主経路)。


## 7. 接続方式の確定 — 端末内 VPN 経由で自分自身に繋ぐ(`springboard-vpn` ブランチ)

「同じ Wi-Fi の PC から繋ぐ」前提をやめ、SideStore / StikDebug(StosDebug)と同じ
**端末内だけで完結する VPN** 方式にした。家の Wi-Fi も PC も要らない。

### 7.1 仕組み(公開ソースで確認した事実)

- **StosVPN**(旧 LocalDevVPN、SideStore/StosVPN リポジトリ `TunnelProv/PacketTunnelProvider.swift`):
  utun に `10.7.0.0/24`(`tunnelDeviceIp = "10.7.0.0"`)を割り当て、`10.7.0.1`(`tunnelFakeIp`)宛ての
  パケットの宛先を `10.7.0.0` に、`10.7.0.0` 発のパケットの送信元を `10.7.0.1` に書き換えて
  そのまま戻すだけ。つまり **`10.7.0.1` に投げると自分自身の lockdownd(全インターフェースで 62078 を待受)に届く**。
  README も "supports offline JIT Enabling" と明記。
- **StosDebug-Legacy**(stossy11/StosDebug-Legacy `StosDebug/Core/Idevice/DeviceManager.swift`)が
  idevice の C FFI でやっている手順がそのまま使える:
  `idevice_pairing_file_read` → `sockaddr_in(10.7.0.1, LOCKDOWN_PORT=62078)` → `idevice_tcp_provider_new`
  → `heartbeat_connect` → 別スレッドで `heartbeat_get_marco` / `heartbeat_send_polo` を回し続ける →
  各サービス(installation_proxy 等)は provider から `*_connect`。
  **heartbeat を回していないと TCP 越しの lockdownd はサービス開始を拒む/切断する**ので、
  StosDebug は `heartbeatReady` が立つまでサービスを使わない。本アプリも同じ(`TsukaimaHeartbeatKeeper`)。
- **StikDebug 最新版**(`StikDebug/Device/JITEnableContext.swift`)は `10.7.0.1:49152` に
  `tunnel_create_rppairing`(RemotePairing トンネル、`rp_pairing_file_read`)で繋ぐ **別方式**。
  §3 で「用途が別」と推測していた 49152 はこれで確定。classic lockdown の SpringBoardServices には使わない
  (fork にも `tunnel_create_rppairing` / `springboard_services_connect_rsd` はあるので、classic が
  iOS 更新で通らなくなったらこちらへ移る余地はある)。
- **SideStore 本体**は minimuxer + em_proxy(usbmuxd エミュレーション)で同じ `10.7.0.1` を使う。
  idevice の tcp provider とは経路が違うが、VPN とペアリングファイルの前提は同じ。

### 7.2 前提(コードの `TsukaimaIdeviceBridge` / 設定画面の案内文と一致させている)

1. **StosVPN が ON であること**。他アプリの NE トンネルの状態は直接問い合わせられないので、
   `getifaddrs` で `10.7.0.0/24` の IPv4 アドレスを持つインターフェースがあるかで判定する
   (`TsukaimaIdeviceBridge.isVPNInterfacePresent`)。OFF なら FFI を呼ばずに
   `TsukaimaIdeviceError.vpnOff`(「StosVPN を開いて接続してから」)を出す。StosVPN には URL スキームが無い
   (Info.plist に `CFBundleURLSchemes` 無し)ので、アプリから開く導線は作れない。
2. **ペアリングファイル**(この端末を PC とペアリングした記録)。入手は 2 通り:
   - **SideStore から受け取る(推奨)**: 設定の「SideStore から取り込む」が
     `sidestore://pairing?urlname=tsukaima-rec` を開く → SideStore(`SideStore/DeepLinks/URLHandler.swift`
     の `case "pairing"` → `ExportPairingFileHandler`、2026-09-20 に develop へ入った機能)が
     `tsukaima-rec://pairingFile?data=<base64 の plist>` でこのアプリに戻す → `AppRouter.open` →
     `TsukaimaPairingFileStore.importIfPairingCallback` が保存。`sidestore` は
     `LSApplicationQueriesSchemes` に登録済み(`canOpenURL` で存在確認するため)。
     SideStore がこの機能の無い版なら `canOpenURL` は true でも何も返ってこない → 次の方法へ。
   - **ファイルから**: PC の jitterbugpair(SideStore 公式手順と同じ)で作った `*.mobiledevicepairing` /
     plist を「ファイル」アプリ経由で `.fileImporter` から取り込む。
   どちらも `Documents/Tsukaima/pairingFile.plist` に `NSFileProtectionComplete` で保存(§4)。中身は
   ログ・画面・報告に一切出さない。
3. 接続先は固定: `10.7.0.1:62078`(`TsukaimaIdeviceBridge.vpnHost` / `lockdownPort`)。
   49152 へのフォールバックは撤去した(用途が違うため)。

### 7.3 セッションの流れ(`TsukaimaIdeviceBridge.withSession`)

VPN 確認 → `idevice_pairing_file_from_bytes` → `idevice_tcp_provider_new(10.7.0.1:62078)` →
`heartbeat_connect` → `TsukaimaHeartbeatKeeper`(別 Thread で marco/polo)→
`springboard_services_connect` → `get_icon_state(formatVersion "2")` / `set_icon_state` → 後始末
(heartbeat 停止を最長 20 秒待ってから `idevice_provider_free`。待ちきれなければ解放せずリークさせる)。
FFI のエラーは message を読まず定型文に丸める(ペアリング情報が混ざり得るため)。
注意(fork/upstream の癖): `springboard_services_connect` は**接続失敗時に provider を自分で解放する**
(`ffi/src/springboardservices.rs` の Err 側 `Box::from_raw(provider)`。`heartbeat_connect` は解放しない)。
そのためセッションはこの経路を通ったら `providerDisowned` を立てて close() で二重解放しない。
`plist_to_xml` の出力は C の `free` ではなく `plist_mem_free`(plist.h)で返す。

## 8. 配置案の受け取りと適用(`set_icon_state`)

画面: 設定 › ホーム画面の配置 › `TsukaimaSpringboardLayoutView`。

1. 「現在の配置を読み取る」→ plist XML をそのまま保持(`TsukaimaIconState.xml`)し、型付きの写し
   (ページ/Dock/フォルダ/その他)を表示。
2. 配置案を受け取る: **hub から**(`GET /api/springboard/proposal`、404 なら案内)か、**JSON を貼り付け**。
   「現在の配置を hub に送る」(`POST /api/springboard/current`、同じ JSON 形式)もある。
   どちらも `TsukaimaAPI.shared`(api.yusukedoi.com + 端末の合鍵)経由。
3. `TsukaimaIconLayout.apply` が現在の plist に配置案を当て、差分(移動するアプリ・作る/無くなるフォルダ・
   配置案に無いアプリ・端末に無いアプリ・個数の警告)を出す。**ここでは書き込まない。**
4. 「この配置を適用する」→ 確認ダイアログ → 適用前の XML を `Documents/Tsukaima/iconstate-backups/` に
   保存(直近 5 件)→ `set_icon_state` → 読み直して表示。
5. 「元に戻す」→ 最新のバックアップをそのまま `set_icon_state`。

### 8.1 配置案 JSON の形式(hub が返す / 手貼りする)

```json
{
  "version": 1,
  "note": "説明(任意。画面に出す)",
  "unlisted": "append",
  "dock": ["com.apple.mobilesafari", "com.apple.MobileSMS", "com.apple.mobilephone", "com.apple.Music"],
  "pages": [
    [
      "com.apple.mobilecal",
      "com.apple.reminders",
      { "folder": "大学", "pages": [["com.google.classroom", "com.apple.mobilemail"]] }
    ],
    [
      "jp.co.yahoo.ipn.appli"
    ]
  ]
}
```

- アプリは **bundle id の文字列**。フォルダは `{"folder": "名前", "pages": [[bundle id, …], …]}`
  (フォルダの中にフォルダは不可。`pages` を省くと空フォルダ扱い)。
- `dock` が空配列/省略なら **今の Dock を維持**。
- `unlisted`: 配置案に出てこない端末上のアプリの扱い。`"append"`(既定)= 末尾に新しいページを足して
  24 個ずつ並べる / `"keep"` = 元のページ番号に残す。**アプリを消すことはできない**(SpringBoard 側で
  消えたアプリは App Library に落ちるだけなので、意図的に「消す」機能は作らない)。
- 同じ bundle id が 2 回出たらエラー。端末に無い bundle id は差分に「無視」と出して飛ばす。
- ウィジェット等(`displayIdentifier` の無い項目)は辞書をそのまま元のページ番号に残す(フォルダ内の
  ものは同名フォルダの先頭ページへ。同名フォルダが無ければ末尾ページ)。
- 1 ページ 24 個・Dock 4 個を超えると警告(止めない。iPad やモデルで違うため)。
- 「現在の配置を hub に送る」「JSON でコピー」は同じ形式で、`{"other": "種別"}` が混ざる(ウィジェット等)。
  hub はそれを **無視して** 配置案を作ればよい(配置案側に `other` は書かない)。

hub 側(portal-bot)の受け口は本人が別途作る。契約:
- `GET /api/springboard/proposal` → 上の JSON(無ければ 404)。
- `POST /api/springboard/current` ← 上の形式(`other` 混じり)。返答は 2xx なら何でもよい。
- 認証は既存の `Authorization: Bearer <端末の合鍵>`(署名・ステップアップは付けていない。
  必要なら `TsukaimaSpringboardLayoutView` の `sendJSON`/`getJSON` の引数に `signed:`/`stepup:` を足す)。

### 8.2 plist の扱い(実機で違ったらここだけ直す)

`TsukaimaIconLayout` が見るキー: `iconLists`(ページの配列)・`buttonBar`(Dock)・
`displayIdentifier`/`bundleIdentifier`(アプリ)・`listType == "folder"` + `displayName` + 入れ子の
`iconLists`(フォルダ)。**辞書の中身は書き換えず、並べ直すだけ**(新規フォルダだけ
`displayName`/`listType`/`iconLists` の 3 キーで作る)。読み取りは `formatVersion "2"` で要求
(libimobiledevice の sbmanager と同じ)。書き込みは `springboard_services_set_icon_state`
(formatVersion 無し)。

## 9. 実機確認(チェックリスト。hub には Swift も実機も無いので未確認)

前提: StosVPN ON、SideStore からペアリングファイル取り込み済み、`IDevice.xcframework` は CI が取り込む。

- [ ] **ビルド**: CI(build.yml)が通る。特に `heartbeat_connect` / `plist_from_xml` / `inet_pton` /
      `getifaddrs` のシンボルが `import IDevice` / `Darwin` で解決される(cbindgen ヘッダ + libplist 連結)。
- [ ] **VPN 判定**: StosVPN OFF で設定画面の「端末内 VPN」が OFF、「現在の配置を読み取る」が
      押せず(または押すと vpnOff の案内)。ON にして前面に戻すと「接続中」に変わる
      (`didBecomeActive` で読み直す)。もし ON でも OFF 表示なら、StosVPN の utun アドレスが
      `10.7.0.0/24` ではない(`isVPNInterfacePresent` の prefix を直す)。
- [ ] **SideStore からの取り込み**: 「SideStore から取り込む」→ SideStore が開いて戻ってくる →
      「取り込み済み」になる。戻ってこない場合は SideStore の版が古い(2026-09-20 以降の develop)。
      赤い文が出る場合は base64 → plist の判定(`looksLikePairingPlist` のキー名)が SideStore の
      出力と合っていない。
- [ ] **接続**: 「現在の配置を読み取る」でページ数・Dock・アプリ数が出る。
      失敗の切り分け: `connectionFailed` = TCP/TLS(VPN・ペアリングファイルの端末不一致)、
      `heartbeatFailed`/`serviceFailed` = heartbeat 中に切れた・サービス開始拒否。
      ここで通らない場合は §7.1 の RemotePairing 方式(49152 + `springboard_services_connect_rsd`)
      への切り替えを検討。
- [ ] **plist のキー**: ページ数が 0/「iconLists が見つかりません」と出たら、画面に出る
      トップレベルキー一覧を見て `TsukaimaIconLayout` のキー名を直す。
- [ ] **差分の妥当性**: 「JSON でコピー」した現在の配置をそのまま貼り付けると差分が「今の配置と同じ」になる
      (往復で壊れていないことの確認)。
- [ ] **適用(小さく)**: アプリ 1 個だけ別ページに動かす配置案で適用 → ホーム画面に反映される
      (SpringBoard が再描画するまで数秒)。反映されない/弾かれる(`setRejected`)なら
      `set_icon_state_with_version(…, "2")` を試す(fork に関数あり、ブリッジに 1 行足すだけ)。
- [ ] **フォルダ**: 新規フォルダを作る配置案で、フォルダ名と中身が反映される
      (3 キーだけの辞書で足りるか。足りなければ既存フォルダの辞書を雛形にする)。
- [ ] **ウィジェット**: ウィジェットのあるページで往復して、ウィジェットが消えない・位置が許容範囲。
- [ ] **元に戻す**: 適用後に「元に戻す」で適用前と同じ配置に戻る。
- [ ] **hub 連携**: `POST /api/springboard/current` が 2xx、`GET /api/springboard/proposal` が
      404 のとき案内文が出る(hub 側実装後は配置案が差分に出る)。
- [ ] **後始末**: 読み取り→適用を何度か繰り返してもクラッシュしない(heartbeat スレッドの停止と
      provider 解放の順序。停止待ち 20 秒を超える場合はログ無しでリークする設計)。
