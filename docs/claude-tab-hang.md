# Claude タブ(段階2)の停止: 調べた経緯と対処

更新: 2026-10-05。担当: Claude タブ専任セッション。

## 症状
- 新しいタイムライン(ClaudeTimelineView, ScrollView + LazyVStack)で、アプリのメインスレッドが 80〜110 秒、SwiftUI の更新から出てこなくなる。
- XCUITest では「Timed out while evaluating UI query」「main thread busy for 30.0s」になる(フォーカスのテスト 13 件が失敗)。
- UITests-Runner の signal trap は、テストコード側(focusComposer の hasFocus の確認)の別の問題で、アプリの停止の副作用。

## 調べ方
- `ClaudeHangWatchdog`(モック時だけ動く。メインスレッドが 3 秒止まったら、止まっている最中のスタックを書く)で 26 件を集めた。
  すべて SwiftUI の描画の更新の中(LazyVStack の配置・ScrollViewAdjustedState.adjustOffsetIfNeeded・ForEach)で、アプリの view の body は出てこなかった。
- 切り分け(CI の run、停止の秒数。同じ 4 テストを回す):
  - scrollTo を全部外す → 停止ほぼ無し(scrollTo が引き金)。
  - LazyVStack → VStack → 小さい履歴では通る(遅延レイアウトとの組み合わせ)。
  - 最下部の判定の書き手を 1 つにする・行の二重 id を外す・scrollTo を後ろへずらす・defaultScrollAnchor(.bottom) だけにする → いずれも停止が残る。
  - **ScrollView + LazyVStack をやめて List にする → 停止無し(記録 0)。** テスト 3 件が通った。

## 対処
- ClaudeTimelineView を List にする。scrollTo・最下部の判定(iOS 18 は onScrollGeometryChange、iOS 17 は目印の出入り)はそのまま。
- UI テストは List が scrollView ではないので `app.scrollViews[...]` をやめて、identifier で探す。

## 実機で確かめること(未確認)
- List の見た目(行の余白・背景・選択)、長い会話のスクロール、ストリーミング中の追従。
