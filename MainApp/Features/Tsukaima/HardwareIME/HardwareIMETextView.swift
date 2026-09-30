import AzooKeyUtils
import GameController
import UIKit

/// ハードウェアキーボードのキーを HardwareIMECore に流し、編集中の文字列を marked text(下線)で見せる UITextView。
///
/// iOS ではサードパーティのキーボード拡張にハードウェアキーボードの入力は届かないので、
/// 本体アプリのテキストビューが自分で受ける。ソフトウェアキーボード(使い魔キー)からの入力には触らない:
/// 物理キーは `pressesBegan` にしか来ないので、そこで IME が消費したものだけ `super` に渡さない。
/// `insertText` 側の分岐は、pressesBegan を通らずに文字が来た場合(OS のバージョン差)の保険。
final class HardwareIMETextView: UITextView {
    let ime: HardwareIMECore
    /// 候補バーなどの再描画(HardwareIMESession が差す)
    var onIMEStateChange: (() -> Void)?

    private var swallowedPresses = Set<UIPress>()
    private var lastHardwarePressAt: TimeInterval = 0
    private var suppressNextInsert: String?

    init(ime: HardwareIMECore) {
        self.ime = ime
        super.init(frame: .zero, textContainer: nil)
        ime.onStateChange = { [weak self] in self?.onIMEStateChange?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 物理キーボードが繋がっているか(GameController の GCKeyboard で見る)
    static var hardwareKeyboardAttached: Bool {
        GCKeyboard.coalesced != nil
    }

    // MARK: - キー → IME

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            lastHardwarePressAt = ProcessInfo.processInfo.systemUptime
            if let key = press.key, let imeKey = Self.imeKey(for: key), consume(imeKey) {
                swallowedPresses.insert(press)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty {
            super.pressesBegan(rest, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(swallowedPresses)
        swallowedPresses.subtract(presses)
        if !rest.isEmpty {
            super.pressesEnded(rest, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(swallowedPresses)
        swallowedPresses.subtract(presses)
        if !rest.isEmpty {
            super.pressesCancelled(rest, with: event)
        }
    }

    /// 編集中だけ矢印・Esc・Tab・F6〜F10 をシステムより先に受け取る(UIKeyCommand は pressesBegan より優先される)
    override var keyCommands: [UIKeyCommand]? {
        guard ime.mode == .kana, ime.isComposing else {
            return super.keyCommands
        }
        let commands: [(String, UIKeyModifierFlags, Selector)] = [
            (UIKeyCommand.inputUpArrow, [], #selector(imeUp)),
            (UIKeyCommand.inputDownArrow, [], #selector(imeDown)),
            (UIKeyCommand.inputLeftArrow, [], #selector(imeLeft)),
            (UIKeyCommand.inputRightArrow, [], #selector(imeRight)),
            (UIKeyCommand.inputEscape, [], #selector(imeEscape)),
            ("\t", [], #selector(imeTab)),
            ("\t", .shift, #selector(imeShiftTab)),
            (UIKeyCommand.inputF6, [], #selector(imeF6)),
            (UIKeyCommand.inputF7, [], #selector(imeF7)),
            (UIKeyCommand.inputF8, [], #selector(imeF8)),
            (UIKeyCommand.inputF9, [], #selector(imeF9)),
            (UIKeyCommand.inputF10, [], #selector(imeF10)),
        ]
        return commands.map { input, flags, action in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        } + (super.keyCommands ?? [])
    }

    @objc private func imeUp() { _ = consume(.up) }
    @objc private func imeDown() { _ = consume(.down) }
    @objc private func imeLeft() { _ = consume(.left) }
    @objc private func imeRight() { _ = consume(.right) }
    @objc private func imeEscape() { _ = consume(.escape) }
    @objc private func imeTab() { _ = consume(.tab) }
    @objc private func imeShiftTab() { _ = consume(.shiftTab) }
    @objc private func imeF6() { _ = consume(.f6) }
    @objc private func imeF7() { _ = consume(.f7) }
    @objc private func imeF8() { _ = consume(.f8) }
    @objc private func imeF9() { _ = consume(.f9) }
    @objc private func imeF10() { _ = consume(.f10) }

    /// UIKey → IME のキー。nil はこのテキストビューが普通に処理するキー(⌘C など)。
    static func imeKey(for key: UIKey) -> HardwareIMEKey? {
        let mods = key.modifierFlags.intersection([.command, .control, .alternate, .shift])
        let shift = mods.contains(.shift)
        let plain = mods.isEmpty
        switch key.keyCode {
        case .keyboardCapsLock:
            return .toggleMode
        case .keyboardLANG1:
            return .toKana
        case .keyboardLANG2:
            return .toAlnum
        case .keyboardSpacebar:
            if mods.contains(.control) || mods.contains(.command) {
                return .toggleMode
            }
            return shift ? .shiftSpace : (plain ? .space : nil)
        case .keyboardReturnOrEnter, .keypadEnter:
            return plain ? .enter : nil
        case .keyboardEscape:
            return plain ? .escape : nil
        case .keyboardTab:
            return plain ? .tab : (mods == .shift ? .shiftTab : nil)
        case .keyboardDeleteOrBackspace:
            return plain ? .backspace : nil
        case .keyboardDeleteForward:
            return plain ? .deleteForward : nil
        case .keyboardUpArrow:
            return plain ? .up : nil
        case .keyboardDownArrow:
            return plain ? .down : nil
        case .keyboardLeftArrow:
            return plain ? .left : nil
        case .keyboardRightArrow:
            return plain ? .right : nil
        case .keyboardF6:
            return plain ? .f6 : nil
        case .keyboardF7:
            return plain ? .f7 : nil
        case .keyboardF8:
            return plain ? .f8 : nil
        case .keyboardF9:
            return plain ? .f9 : nil
        case .keyboardF10:
            return plain ? .f10 : nil
        default:
            // Ctrl+H のような編集ショートカットは IME に渡さず、テキストビューに任せる
            guard mods.subtracting(.shift).isEmpty else {
                return nil
            }
            let chars = key.characters
            guard chars.count == 1, let c = chars.first, c.isASCII, !c.isNewline, c != " ", c != "\t" else {
                return nil
            }
            return .character(c)
        }
    }

    /// IME に渡し、消費されたら効果を適用して true
    @discardableResult
    private func consume(_ key: HardwareIMEKey) -> Bool {
        let result = ime.handle(key)
        guard result.handled else {
            return false
        }
        apply(result.effects)
        return true
    }

    // MARK: - 効果 → テキストビュー

    func apply(_ effects: [HardwareIMEEffect]) {
        guard !effects.isEmpty else {
            return
        }
        for effect in effects {
            switch effect {
            case .setMarked(let text, let cursor):
                let offset = String(text.prefix(cursor)).utf16.count
                setMarkedText(text, selectedRange: NSRange(location: offset, length: 0))
            case .commit(let text):
                if markedTextRange != nil {
                    setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
                    unmarkText()
                } else {
                    suppressNextInsert = nil
                    super.insertText(text)
                }
            case .clearMarked:
                if markedTextRange != nil {
                    setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
                    unmarkText()
                }
            }
        }
        delegate?.textViewDidChange?(self)
    }

    /// 「変換」の左文脈(zenz 用): カーソル(編集中なら marked の手前)より左のテキスト
    func leftContextText() -> String {
        let end: UITextPosition = markedTextRange?.start ?? selectedTextRange?.start ?? endOfDocument
        guard let range = textRange(from: beginningOfDocument, to: end), let s = text(in: range) else {
            return ""
        }
        return String(s.suffix(40))
    }

    // MARK: - 保険: pressesBegan を通らずに来た入力

    override func insertText(_ text: String) {
        if ime.mode == .kana, text.count == 1, let c = text.first,
           ProcessInfo.processInfo.systemUptime - lastHardwarePressAt < 0.3,
           ime.isComposing || (c.isASCII && c.isLetter) || HardwareIMECore.punctuation[c] != nil {
            // 物理キーの直後に来た 1 文字。pressesBegan で消費できていればここには来ない。
            let key: HardwareIMEKey = c == " " ? .space : (c == "\n" ? .enter : (c == "\t" ? .tab : .character(c)))
            if consume(key) {
                return
            }
        }
        super.insertText(text)
    }

    override func deleteBackward() {
        if ime.mode == .kana, ime.isComposing, consume(.backspace) {
            return
        }
        super.deleteBackward()
    }

    override func resignFirstResponder() -> Bool {
        apply(ime.commitAll())
        HardwareIMEConverter.shared.flushLearning()
        return super.resignFirstResponder()
    }
}
