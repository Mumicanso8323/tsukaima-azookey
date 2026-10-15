# FocusGuard(物理キーボード接続中の入力欄のフォーカス)

更新: 2026-10-05。担当: Claude タブ専任セッション。設計の材料: 使い魔ブラインドの調査 `~/.claude/handoffs/tsukaima-blind/focus-audit.md`。

## 要件(本人)
- Bluetooth キーボード接続中は、入力欄からフォーカスが外れる瞬間が一度もあってはならない(入力欄が画面に1つだけのとき)。
- ただし、別の入力欄を押せば移れる。iOS 標準の IME(候補・変換中の文字・ソフトウェアキーボード・絵文字)は閉じられる・切り替えられる。変換中の文字を消さない。
- 接続が切れたら直ちに固定を解く。接続の入れ替わりで暴れない。

## 仕組み(MainApp/Features/Tsukaima/HardwareIME/FocusGuard.swift)
- 拒否(`canResignFirstResponder` を false)はしない。別の欄へ移れず、IME を閉じられなくなるため。
- 外れた入力欄を `becomeFirstResponder` だけで戻す。未確定の文字・選択範囲には触れない。
- 対象は `pinsFocus: true` の欄だけ(Claude タブの入力欄と使い魔チャット)。設定など欄が複数ある画面は対象外。
- 戻す条件(`FocusGuardPolicy.decide`、純関数): 物理キーボードが繋がっている(GCKeyboard をその場で読む)/本人が別の欄を選んでいない/
  別の欄が画面に見えていない/シート・アラートが出ていない/アクティブでキーウィンドウ/接続の変化の直後 1 秒ではない/アプリが意図した resign ではない。
- 戻すのは 5 秒に 3 回まで(次に本人が欄を触るまで止める)。
- 別の欄が一瞬見えただけでは意思を捨てない。10 秒見えたままなら時間での再判定をやめ(idle)、アクティブ化・画面復帰・キーウィンドウの変化で判定し直す。
- 履歴のスクロールで `.scrollDismissesKeyboard(.interactively)` が入力欄を外していたので、接続中は `.never` にする。

## 既知の限界(正直な記録)
- 本人がキーボードを閉じたことの見分け: ソフトウェアキーボードが出ている間に、アクティブな状態で、システム要因と分かっていない外れは「本人が閉じた」とみなして戻さない。
  このため、物理キーボードとソフトウェアキーボードを併用している間の「勝手に外れる」は固定されない。
  keyboardWillHide の順序で見分ける案は、本人の閉じるもシステム要因も同じ通知になるため採らなかった。実機で挙動が分かってから扱う。
- Menu / ContextMenu の表示中に戻してメニューを閉じてしまわないかは未確認(キーウィンドウの判定に頼っている)。
- HW キーボードが接続されたときに何もフォーカスされていなければ、初期フォーカスは取らない(段階2)。

## 実機でしか確かめられないこと(未確認)
- 本物の Bluetooth キーボードでの動き(GCKeyboard の通知の順序、スリープ復帰)。
- 閉じるキーでの textViewDidEndEditing と keyboardWillHide の順序、iPad のショートカットバー、浮かぶ・分割キーボード、Stage Manager。
- シートを閉じた後・システムの許可ダイアログの後の復帰。Full Keyboard Access の Tab。

## テスト
- 単体: `azooKeyTests/FocusGuardPolicyTests.swift`(判定表・OtherFieldVisibility・SoftKeyboardTracker)。
- UI: `MainAppUITests/ClaudeHardwareFocusUITests.swift`(`--claude-hw-keyboard` で接続中として扱い、`-claude.hwLossInterval` などでアプリ側のタイマがフォーカスを奪う)。
  復帰・上限とリセット・本人が閉じたものを戻さない・スクロールで外れない、を確かめる。
- CI: build.yml の `hwfocus_only` で、この UI テストと test6 だけを回せる。
