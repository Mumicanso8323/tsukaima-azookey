import Foundation
import UIKit

/// 入力欄の「カーソルを置いておきたい」という本人の意図(純ロジック・HardwareIMETextEditor の Coordinator が持つ)。
///
/// UIKit は画面の作り直し・メニューやシートの表示・タブの付け替えなどで勝手に first responder を手放す。
/// それらは本人の意図ではないので、意図が残っている限り次のランループで付け直す(= `.restore`)。
/// 意図が消えるのは本人が明示的に閉じたときだけ(Esc・閉じるボタン・タブ切替)。送信は閉じる扱いにしない。
struct ComposerFocusIntent: Equatable {
    enum Event: Equatable {
        /// 本人が欄をタップした/物理キーで打ち始めた(textViewDidBeginEditing)
        case userBeganEditing
        /// 親が focused=true にした(定型文の差し込み・画面を開いた直後など)
        case parentRequestedFocus
        /// 本人が明示的に閉じた(Esc・キーボードを閉じるボタン・タブを離れた)
        case userDismissed
        /// UIKit が first responder を手放した(理由は問わない: メニュー・シート・再描画・IME の付け替え…)
        case editingEnded
        /// 送信した(欄を空にする・ボタンの状態が変わる・一覧が伸びる。どれも閉じる理由にならない)
        case sent
    }

    enum Action: Equatable {
        case none
        /// 次のランループで becomeFirstResponder し直す
        case restore
    }

    private(set) var wantsFocus = false

    mutating func apply(_ event: Event) -> Action {
        switch event {
        case .userBeganEditing, .parentRequestedFocus:
            wantsFocus = true
            return .none
        case .userDismissed:
            wantsFocus = false
            return .none
        case .editingEnded, .sent:
            return wantsFocus ? .restore : .none
        }
    }
}

/// 入力欄にカーソルを置いたまま効く物理キーボードのショートカット一覧(割り当てはこの表だけで決める)。
/// `uiKeyCommands` が ⌘ 長押しの一覧(UIKeyCommand の discoverabilityTitle)にも同じ文言で出る。
/// 素の ↑/↓/数字/Space/Enter はここに入れない(欄が空のときだけ選択肢の操作に使う: ComposerPlainKey)。
enum ComposerKeyBinding: CaseIterable, Equatable {
    case scrollLinesUp, scrollLinesDown
    case scrollPageUp, scrollPageDown
    case scrollTop, scrollBottom
    case choose1, choose2, choose3, choose4, choose5, choose6, choose7, choose8, choose9
    case toggleMic

    struct Spec: Equatable {
        let input: String
        let modifiers: UIKeyModifierFlags
        let title: String
    }

    /// 同じ操作に複数のキーを割り当てるものがある(PageUp と Option+Shift+↑ など)
    var specs: [Spec] {
        switch self {
        case .scrollLinesUp:
            return [Spec(input: UIKeyCommand.inputUpArrow, modifiers: .alternate, title: "履歴を数行上へ"),
                    Spec(input: UIKeyCommand.inputUpArrow, modifiers: .control, title: "履歴を数行上へ")]
        case .scrollLinesDown:
            return [Spec(input: UIKeyCommand.inputDownArrow, modifiers: .alternate, title: "履歴を数行下へ"),
                    Spec(input: UIKeyCommand.inputDownArrow, modifiers: .control, title: "履歴を数行下へ")]
        case .scrollPageUp:
            return [Spec(input: UIKeyCommand.inputPageUp, modifiers: [], title: "履歴を1画面上へ"),
                    Spec(input: UIKeyCommand.inputUpArrow, modifiers: [.alternate, .shift], title: "履歴を1画面上へ")]
        case .scrollPageDown:
            return [Spec(input: UIKeyCommand.inputPageDown, modifiers: [], title: "履歴を1画面下へ"),
                    Spec(input: UIKeyCommand.inputDownArrow, modifiers: [.alternate, .shift], title: "履歴を1画面下へ")]
        case .scrollTop:
            return [Spec(input: UIKeyCommand.inputUpArrow, modifiers: .command, title: "履歴の先頭へ")]
        case .scrollBottom:
            return [Spec(input: UIKeyCommand.inputDownArrow, modifiers: .command, title: "最新へ")]
        case .toggleMic:
            return [Spec(input: "m", modifiers: [.command, .shift], title: "音声入力の開始/停止")]
        default:
            guard let n = chooseNumber else { return [] }
            return [Spec(input: "\(n)", modifiers: .command, title: "選択肢 \(n) を選ぶ")]
        }
    }

    /// choose1〜9 の番号(それ以外は nil)
    var chooseNumber: Int? {
        switch self {
        case .choose1: 1
        case .choose2: 2
        case .choose3: 3
        case .choose4: 4
        case .choose5: 5
        case .choose6: 6
        case .choose7: 7
        case .choose8: 8
        case .choose9: 9
        default: nil
        }
    }

    static func choose(_ n: Int) -> ComposerKeyBinding? {
        allCases.first { $0.chooseNumber == n }
    }

    /// (input, modifiers) → binding。pressesBegan/UIKeyCommand の両方から引く
    static func match(input: String, modifiers: UIKeyModifierFlags) -> ComposerKeyBinding? {
        let mods = modifiers.intersection([.command, .control, .alternate, .shift])
        return allCases.first { b in b.specs.contains { $0.input == input && $0.modifiers == mods } }
    }
}

/// 欄が空で変換中でもないときだけ、素のキーを選択肢の操作に回す(ComposerKeyHandler が true を返せば消費)。
enum ComposerPlainKey: Equatable {
    case digit(Int)
    case up, down
    case space
    case enter
    case escape
}
