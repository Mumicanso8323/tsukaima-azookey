# バイト中のブロック(Screen Time API 試作)

状態: 試作。**配布しない**(SideStore の無料枠では family-controls が付かない。下記)。

## 構成
- `TsukaimaScreenTimeShared/WorkShiftBlockCore.swift` — 選択(FamilyActivitySelection)を App Group に保存、盾の適用/解除、DeviceActivity の予約。
- `TsukaimaMonitor/` — DeviceActivityMonitor 拡張。区間の開始で盾を立て、終了で外す(アプリが動いていなくても OS が呼ぶ)。
- 設定 → 使い魔キットの設定 →「バイト中のブロック」(`WorkShiftBlockView`)— 許可・アプリ選択・「今から15分ブロック」・解除。

## 予定との連動(サーバ側の設計。まだ未実装)
- `GET /api/work-shifts?from=YYYY-MM-DD&days=7` → `[{ "date": "2026-10-12", "start": "06:00", "end": "18:00" }]`
  - portal-bot の events から title が "GL" の日を拾い、開始前 3 時間〜終了(既定 6:00〜18:00)に丸める。
- アプリは起動時と BGAppRefreshTask(夜)で取得し、日ごとに `DeviceActivityCenter.startMonitoring("workShift.day.<日付>")` を張り直す
  (同時に監視できる数に上限があるので直近 7 日ぶんだけ。消えた日は stopMonitoring)。
- 予定が当日に変わった場合はサーバからサイレントプッシュ or アプリ起動時の再取得で追従(アプリが動かない日は古い予約のまま)。

## 制約(調べた範囲)
- 区間は 15 分以上(テストも15分)。
- 盾にできるのは選択画面で選んだトークンだけ。名前は読めない。電話・カメラ等は選ばなければ生きる。
- 利用者は 設定 → スクリーンタイム →「スクリーンタイムへのアクセスを許可したApp」でいつでも許可を外せる(スクリーンタイムのパスコードは要らない)。
- 署名: family-controls は無料 Apple ID では付かない。有料プログラムなら開発用は即時、TestFlight/配布は Apple への申請が要る。
