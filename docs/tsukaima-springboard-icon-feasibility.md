# ホーム画面アイコン配置の読み取り/設定 — 実現可能性調査(PC・自宅 Wi-Fi 無し)

対象ブランチ: `merge-kit`。実装コードはこの調査では**書かない**(下記「結論」参照)。

## ゴール(依頼内容)
使い魔アプリを iPhone 上で動かしたまま、PC も自宅 Wi-Fi も使わずに、SideStore/StikDebug と同じ手口
(LocalDevVPN のループバック VPN + lockdown ペアリングファイル)で自分の端末の lockdownd 経由 SpringBoardServices
(`get_icon_state`/`set_icon_state`)を叩き、ホーム画面のアイコン配置を読む(将来的には書く)。

## 結論: 現時点では「最小限の実装」までは進めない

**プリビルドの xcframework をそのまま使う経路は無い。** `jkcoxson/idevice` の Rust コアには
`get_icon_state`/`set_icon_state` が存在するが、iOS/Swift 向けに配布されている C FFI 層(`ffi/` クレート、
これがそのまま `idevice-xcframework-*.zip` としてビルドされて GitHub Releases に載る)には、この 2 つの
コマンドを呼ぶ関数が**一つも生えていない**(根拠は下記「1」)。GitHub 全体のコード検索でも、Swift/iOS 側から
`get_icon_state`/`setIconState` を叩いている例はゼロ(pymobiledevice3 や libimobiledevice の Python/C 実装しか無い)。
つまり、これを実現するには **Rust 側に FFI 関数を自分で足して、iOS 向けにクロスコンパイルして
xcframework を自前で作る**必要があり、これは依頼文が「実装を止めて計画のみにする」条件として挙げていた
「Rust を CI でそこそこの手間をかけてコンパイルする必要がある」にそのまま該当する。
よって、**デバッグボタンの実装・CI 実行・publish は行わなかった**。以下は次にやる場合の設計。

## 調査結果(根拠つき)

### 1. `get_icon_state`/`set_icon_state` は Rust コアにはあるが、C FFI・配布 xcframework には無い
- Rust コア本体: `idevice/src/services/springboardservices.rs`(`jkcoxson/idevice`, `master` HEAD 時点)
  に `SpringBoardServicesClient::get_icon_state` / `set_icon_state` / `set_icon_state_with_version` が実装済み。
  コメントに "This method successfully reads the home screen layout on all iOS versions." とあり、機能自体は
  安定している。
  https://github.com/jkcoxson/idevice/blob/master/idevice/src/services/springboardservices.rs
- ところが C FFI 層 `ffi/src/springboardservices.rs` が公開しているのは
  `springboard_services_connect` / `_connect_rsd` / `_new` / `_get_icon`(単一アプリの PNG)/
  `_get_home_screen_wallpaper_preview` / `_get_lock_screen_wallpaper_preview` /
  `_get_interface_orientation` / `_get_homescreen_icon_metrics` / `_free` のみ。
  `get_icon_state`/`set_icon_state` に対応する `#[unsafe(no_mangle)]` 関数は存在しない。
  https://github.com/jkcoxson/idevice/blob/master/ffi/src/springboardservices.rs
- GitHub コード検索で `icon_state` を `repo:jkcoxson/idevice` に絞ると、ヒットするのは
  `idevice/src/services/springboardservices.rs`・`idevice/src/utils/plist.rs`・
  `tools/src/springboardservices.rs`(CLI ツール)・`tests/src/springboard.rs` の 4 箇所だけで、
  `ffi/` 配下には一切出てこない(2026-09-30 確認)。CLI ツール `idevice-tools` には
  `get_icon_state`/`set_icon_state` サブコマンドがある(`tools/src/springboardservices.rs`)が、
  これは macOS/Linux/Windows 向けバイナリで、iOS では動かせない。
- `IdeviceHandle` レベルでも、任意の plist コマンドを送受信できる汎用 FFI(`idevice_send_plist`的なもの)は
  公開されていない(`ffi/src/lib.rs` の `pub unsafe extern` 関数一覧を確認、接続/セッション/解放系のみ)。
  つまり「既存の FFI 関数を組み合わせて回避する」抜け道も無い。
  https://github.com/jkcoxson/idevice/blob/master/ffi/src/lib.rs
- **プリビルド配布は存在する**: `idevice-xcframework-v0.1.68.zip`(2026-09-15、約 200MB)を含め
  ほぼ毎リリースで xcframework が GitHub Releases に付いている。
  https://github.com/jkcoxson/idevice/releases
  ただし上記の通り中身に `get_icon_state`/`set_icon_state` が無いので、**この zip をダウンロードするだけでは要件を満たせない**。

### 2. ループバックアドレス・ポート
- `10.7.0.1:49152` が SideStore/StikJIT 系が使う既定のエンドポイント。StikJIT の統合ガイドに明記:
  「Pass `configuration:` when the integration needs to override the tunnel endpoint or five-second
  connection timeout. The default endpoint is `10.7.0.1:49152`.」
  https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md
- 同じ値は無関係の第三者ツールでも確認できる: `xddxdd/sidestore-vpn` の README に
  「SideStore ... instructs iOS to connect to a computer at `10.7.0.1`」、
  `geode-sdk/ios-launcher` の `StikJIT.conf` サンプルに `AllowedIPs = 10.7.0.1/32`(端末側の WireGuard 風設定、
  端末自身のトンネル内アドレスは `10.7.0.10/24` 側)。
  https://github.com/xddxdd/sidestore-vpn/blob/main/README.md
  https://github.com/geode-sdk/ios-launcher/blob/main/screenshots/StikJIT.conf
- iOS 26 でもこのエンドポイントで動く旨が StikJIT ガイドに明記されている(TXM/SPTM=iOS 26 の話題を前提に
  書かれたドキュメント全体で `10.7.0.1:49152` が既定値のまま)。

### 3. ペアリングファイルの扱い(StikJIT の推奨実装、そのまま流用できる)
`docs/…INTEGRATION.md` の「Built-in StikJIT: Store and import the pairing file」節がそのまま使える設計:
- 保存場所: `Documents/StikJIT/pairingFile.plist` 相当(使い魔では `Documents/Tsukaima/pairingFile.plist` 等に読み替え)。
- 取り込み: `UIDocumentPickerViewController` でユーザーがファイルを選ぶ。security-scoped access を使ってコピーし、
  既存ファイルは atomic に置き換える。
- `Info.plist` に `UIFileSharingEnabled`(Finder/AFC 経由でアプリの Documents に置けるようにする)と、
  任意で `LSSupportsOpeningDocumentsInPlace` を追加。
- **内容をログ・画面に絶対出さない**(ガイドに明記、今回の依頼の指示とも一致)。
- 取得元は「AFC/Finder・`idevice_pair`・その他のペアリング手段」で得たものを受け付ける、としている
  ( = pymobiledevice3 や `idevice_pair` で作った `.plist` をそのまま使える形式)。
  https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md

  **今回の環境での現実的な入手経路**: note(Windows)の usbmux ペアリングレコード
  `C:\ProgramData\Apple\Lockdown\00008140-000C74C41403801C.plist` を、note 上の
  `pymobiledevice3`(`C:\Tools\pmd313`)経由でそのままエクスポート/流用できる可能性が高い
  (lockdown ペアリングレコードのフォーマットは usbmux 版も iOS 版も本質的に同じ plist で、
  `idevice_pair`/`pymobiledevice3 lockdown pair` が読み書きする形式と一致する)。
  持っていく方法としては、①その `.plist` を note からファイル共有(iCloud Drive や AirDrop、または
  一時的に有効化した Files アプリ経由)で iPhone に送り、使い魔アプリの「ファイルから読み込む」で
  取り込む、②または portal-bot の認証つき API に一時ダウンロードエンドポイントを生やしてワンタイムリンクで
  配る、のどちらか。**本調査ではどちらも実装していない**(コピーも中身の提示もしていない)。
  秘密情報である点は忘れずに: このペアリングファイルは端末に対する信頼済みコンピュータの鍵そのものなので、
  sync や chat には絶対に貼らない(ユーザーの既存方針どおり)。

### 4. iOS 17+/26 での到達性(RSD の必要性)
- `SpringBoardServicesClient` は **2 系統**の接続を持つ:
  - 従来の lockdown 経由(`IdeviceService::service_name = "com.apple.springboardservices"`、
    lockdownd に `StartService` させてから TCP 接続)。
  - RSD 経由(`#[cfg(feature = "rsd")] impl RsdService for SpringBoardServicesClient`、
    サービス名は `"com.apple.springboardservices.shim.remote"`)。
  https://github.com/jkcoxson/idevice/blob/master/idevice/src/services/springboardservices.rs
- これは「新しい iOS では classic lockdown 経由のサービスの一部が RSD の shim 経由でしか掴めなくなった」ことの
  裏付け(だから idevice 側が両方用意している)。ただし StikJIT の統合ガイドは iOS 26 環境でも
  既定の classic エンドポイント `10.7.0.1:49152` を使い続けている記述で、**lockdownd 自体への到達と
  セッション確立は classic のままで問題ない**ことも同時に読み取れる。
  → 実際に springboardservices が classic 経由で `StartService` できるか、それとも RSD shim 必須かは
  **iOS バージョンと端末の組み合わせで変わりうる**ため、実装時は両方叩けるようにしてフォールバックする設計が安全
  (これも「最小の FFI 追加」では済まない一因: RSD 経由にするなら `core_device_proxy`+`rsd` 機能の
  トンネル確立コードも Swift 側から呼べるようにする必要がある)。

### 5. エンタイトルメント・前提条件
- NetworkExtension(LocalDevVPN 相当)自体は本人が SideStore 用にすでに導入・使用中(前提として確認済み)。
- StikJIT 統合ガイドが求める前提: iOS 17.4+、Developer Mode 有効、ペアリングファイル配置、LocalDevVPN 接続中、
  Wi-Fi が無ければモバイル通信 + LocalDevVPN + 機内モードの組み合わせ。
  https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md
- サイドロードのプレーンなアプリ(App Store 配布ではない)でも動作する前提で書かれている
  (StikJIT 自体が「distribution environment that permits the helper and JIT behavior」= サイドロード前提のツール)。
- Apple による締め付けの兆候: 明示的な記述は見つからなかったが、iOS バージョンごとに classic/RSD の
  使い分けが増えている(上記 4)こと自体が、Apple がサービスごとに徐々に RSD 経由へ寄せていることの
  間接的な兆候。

## 次にやる場合の実装計画(概算)
1. `jkcoxson/idevice` を fork するか、`merge-kit` 用にパッチを当てた `ffi/src/springboardservices.rs` を
   自前で維持し、`springboard_services_get_icon_state` / `_set_icon_state`(plist 入出力は `plist_t` で
   既存の `plist_ffi` を再利用)を追加。RSD 経由の `_connect_rsd` に相当する get/set も同様に。
2. CI(GitHub Actions macOS ランナー)に Rust ツールチェーン + `aarch64-apple-ios`/`aarch64-apple-ios-sim`
   ターゲット追加、`xcodebuild -create-xcframework` でのパッケージング手順を追加。
   `idevice` 本体のビルドスクリプト(`justfile`)に xcframework 生成タスクが既にあるので、それを iOS ターゲット
   向けに実行する形に寄せられる可能性が高い(要確認)。
3. Swift 側: `Documents/.../pairingFile.plist` の import UI(`UIDocumentPickerViewController`)、
   LocalDevVPN 接続中かの判定、`IdeviceProvider`(TCP `10.7.0.1:49152`)→ `LockdownClient` →
   `start_service("com.apple.springboardservices")` → 失敗したら RSD ハンドシェイク経由にフォールバック、
   という接続コードを新設。
4. 設定画面に「ホーム画面を読み取る(実験)」ボタンを追加し、`get_icon_state` の結果からページ数・
   Dock アプリ数だけ表示する read-only デモにする(依頼どおり `set_icon_state` はまだ呼ばない)。
5. CI を `ios-ci run merge-kit` → `ios-ci publish` の順で回す。

見積り工数はステップ 1・2(Rust の FFI 追加 + iOS クロスビルドの CI 整備)が支配的で、
現時点の「最小限の実装」の枠には収まらないため、今回は着手していない。

## 参考リンク(本調査で引用したもの)
- https://github.com/jkcoxson/idevice
- https://github.com/jkcoxson/idevice/blob/master/idevice/src/services/springboardservices.rs
- https://github.com/jkcoxson/idevice/blob/master/ffi/src/springboardservices.rs
- https://github.com/jkcoxson/idevice/blob/master/ffi/src/lib.rs
- https://github.com/jkcoxson/idevice/blob/master/tools/src/springboardservices.rs
- https://github.com/jkcoxson/idevice/releases
- https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md
- https://github.com/xddxdd/sidestore-vpn/blob/main/README.md
- https://github.com/geode-sdk/ios-launcher/blob/main/screenshots/StikJIT.conf
