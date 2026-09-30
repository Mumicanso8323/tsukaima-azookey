# ホーム画面アイコン配置の読み書き — 組み込み手順(続き)

前提: [tsukaima-springboard-icon-feasibility.md](tsukaima-springboard-icon-feasibility.md) の続き。
あちらの結論(「Rust の C FFI に `get_icon_state`/`set_icon_state` が無いので実装は止める」)を受けて、
fork してその FFI を追加した。**このファイルはコードを書かない、組み込み手順のドキュメントのみ**。

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
3. `sockaddr_in` を組み立てて `idevice_tcp_provider_new` に渡す。**ポート番号は未確認のまま残っている
   課題**: fork の `ffi/src/lib.rs` は `LOCKDOWN_PORT = 62078`(通常の USB/TCP 越し lockdownd の
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
