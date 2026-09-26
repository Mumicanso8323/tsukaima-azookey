# 使い魔キット統合(merge-kit)夜間作業レポート

2026年09月27日(日)未明、オーナー就寝中に自律作業。ブランチ: `merge-kit`。

## やったこと

### 1. 使い魔キット(録音・目覚まし)を azooKey 本体に統合

`~/tsukaima-recorder`(使い魔キット 1.2.17)の中身を、`~/src/tsukaima-azookey` の MainApp に
新しい「使い魔」タブとして統合した。

- 新タブ「使い魔」(`MainApp/Features/Tsukaima/`)に、録音・目覚まし・キット設定の3サブタブを移植
  (`TsukaimaTabView` が旧アプリの `@main` 構造体が持っていたシーン監視・URLオープン処理を引き継ぐ)。
- 共有シート「使い魔に送る」を新しい app extension ターゲット `TsukaimaShare` として追加
  (`jp.yusukedoi.tsukaima.azookey.share`)。ファイル・画像・PDF(複数可)を hub の `/api/intake` に送る。
- App Intents(在不在を記録・Apple Pay を記録・スクショを出費に・ヘルスケアを送る)を
  `AppShortcutsProvider`(`TsukaimaShortcuts`)ごと本体に追加。ショートカット/オートメーションの
  候補には、アプリ名が「使い魔」になったことで `使い魔で在不在を記録` のような形で出るはず。
- HealthKit 連携は元のまま `#if HEALTHKIT` の中(無料 Personal Team は HealthKit capability 非対応の
  ため、フラグは立てていない = 今回のビルドでは一切コンパイルされない)。
- キーボード拡張(Keyboard ターゲット)のコードは一切変更していない。
- シンボル衝突を避けるため、`Config`/`Log`/`Net`/`Hub`/`ContentView`/`SettingsView`/`Alarm`/
  `Backup`/`Mic`/`Uplink`/`Provision`/`Recorder` は `Tsukaima` 接頭辞を付けてリネーム
  (元は衝突なし。将来 azooKey 側に同名が増えても安全なように予防的リネーム)。
- 目覚まし復元ロジック(`TsukaimaAlarmLogic` パッケージ)は、新しい SwiftPM ローカルパッケージを
  pbxproj に配線するリスクを避けるため、ロジックそのものを `TsukaimaAlarmRestoreLogic.swift` として
  インライン化した。**ただしこの純ロジックの単体テスト(`AlarmRestoreLogicTests`)は移植していない。**
  必要なら azooKeyTests 側に手動で移すこと。
- アプリ表示名を「使い魔azooKey」→「使い魔」に変更(`Resources/InfoPlist.xcstrings` の ja ローカライズ
  のみ変更。内部の ASCII 名 `TsukaimaAzooKey` は SideStore の App ID 登録失敗を避けるため据え置き)。
- バージョンを 3.2.0 に更新(pbxproj の MARKETING_VERSION、build.yml の VERSION/TAG)。

### 2. Apple Pay 記録インテントに「取引」パラメータを追加

`RecordApplePayIntent`(在 `MainApp/Features/Tsukaima/Intents/ApplePayIntent.swift`、元は
`~/tsukaima-recorder` 側にも同内容をコミット済み)に `transaction`(取引)パラメータを追加した。

- `merchant` / `amount` / `card` はすべて任意化。`transaction` を含めいずれか1つでも指定されていれば送信する。
- JSON では `"transaction"` フィールドとして `/api/spend/applepay` に送る(hub 側の対応は別エージェント作業中とのこと)。
- Wallet の取引オートメーションの「取引」変数をそのまま `取引` パラメータに渡せば、個別に支払先/金額を
  組み立てずに済む。

### 3. UserDefaults・データ移行

**旧アプリ(bundle ID `jp.yusukedoi.tsukaima.recorder`)と新アプリ(`jp.yusukedoi.tsukaima.azookey`)は
別の bundle ID なので、iOS の `UserDefaults.standard` は自動では引き継がれない。** App Group は
どちらの機能(録音・目覚まし・共有拡張)でも使われていなかった(確認済み)ので、移行の手段自体がない。
再設定が必要なもの:

- 目覚ましの時刻・オン/オフ状態(`alarm.*` キー) — **新しい「使い魔」タブでセットし直す必要あり**
- 共有シートの「ルルブとして送る」トグルとメモ(`share.isRulebook` / `share.rulebookNote`)
- ヘルスケア自動送信の最終送信時刻(影響小、`#if HEALTHKIT` 無効なので実質未使用)
- 動作ログ(`alarm.log`) — 消えるが実害はない(hub 送信済み分は hub 側に残っている)
- マイク・通知の許可 — 新しいアプリとして初回に許可し直す必要あり
- Apple Pay 等のショートカット/オートメーション — アプリが差し替わるので、Wallet/ショートカットの
  オートメーション側で紐付け直す(呼び出し先の Intent 名は同じなので、選び直すだけで済むはず)

## 4. クリップボードの「ペーストを許可しますか?」問題 — 設定変更で解決済み、追加調査なし

着手時点で `AzooKeyCore`・`MainApp`・`Keyboard`(3.1.3 の修正 `5f104228` 以降の自動読み取り経路)を
一通り grep していたところで、オーナーが端末側のペースト許可設定を「常に許可」に切り替えたとの
連絡があったため、コード側の原因究明はそこで打ち切った。**未解決ではなく、設定変更により解消済み。**
コード変更なし。

## 5. App ID 数と SideStore 無料枠への影響

- 統合前: 使い魔azooKey(本体+キーボード=2)+ 使い魔キット(本体+共有拡張=2)= **App ID 4個、
  アプリ2本**
- 統合後: 使い魔azooKey(本体+キーボード+共有拡張=3)= **App ID 3個、アプリ1本**
- SideStore 無料アカウントの制約(App ID 登録数上限・再署名の頻度)に対して、App ID を1個、
  かつアプリのインストール枠を1本、それぞれ節約できる。目標どおり。

## 6. CI

- トリガー: `workflow_dispatch`(`merge-kit` ブランチ指定)。`push` の自動トリガー対象ブランチ
  (`main` のみ)は変更していない。
- `.github/workflows/build.yml` の「余計な拡張は落とす」ロジックを、`Keyboard.appex` に加えて
  `TsukaimaShare.appex` も残すように変更。ipa に両方の appex が入っているかのチェックを追加。
- `merge-kit` ブランチでは、通常の `latest` リリースの代わりに **prerelease** `merge-test`
  を作る専用ステップを追加(`gh release create merge-test ... --prerelease`、`--latest` は付けない)。
  `~/portal-bot/data/dist/source.json`(SideStore の追加ソース)には一切触れていない。

<!-- CI 結果はここに追記 -->

## 7. 切り替えるためにオーナーがやること

1. CI が作った prerelease `merge-test` の ipa を確認し、SideStore の「ローカルソース」または
   直接 ipa 読み込みで**新しいビルドを別名でインストール**して動作確認する
   (通常のソース経由の自動更新には流していないので、SideStore にはまだ出てこない)。
2. 動作確認できたら:
   - 「使い魔」タブでマイク許可 → 目覚まし時刻の再設定
   - 共有シート「使い魔に送る」が候補に出るか確認
   - ショートカット/オートメーション(在不在・Apple Pay・スクショ)を新アプリの Intent に選び直す
3. 問題なければ、**オーナー自身の手で**旧「使い魔azooKey」(3.1.3)と「使い魔キット」(1.2.17)を
   削除する(このセッションでは削除していない)。
4. `merge-kit` を `main` にマージし、通常の(latest)リリースフローに乗せる。

## 8. 既知の未対応・積み残し

- `TsukaimaAlarmLogic` の単体テスト(`AlarmRestoreLogicTests`)は azooKeyTests に移植していない。
- Share 拡張・使い魔タブ用の新しい UI テストは追加していない(既存の `azooKeyTests` /
  `azooKeyUITests` はそのまま)。
