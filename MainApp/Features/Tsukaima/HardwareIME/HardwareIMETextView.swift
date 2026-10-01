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
    /// 素の Enter(変換中でない)で呼ぶ。nil なら従来どおり改行が入る。Shift+Enter は常に改行。
    var onSubmit: (@MainActor () -> Void)?
    /// 欄が空で変換中でもないときの素のキー(数字・↑↓・Space・Enter・Esc)。true を返したら消費(選択肢の操作)。
    /// Esc は欄の中身に関係なく、変換中でなければ常に聞く(入力欄を閉じる合図)。
    var onPlainKey: (@MainActor (ComposerPlainKey) -> Bool)?
    /// 修飾キーつきのショートカット(ComposerKeyBinding の表)。true を返したら消費。nil なら一覧にも出さない。
    var onBinding: (@MainActor (ComposerKeyBinding) -> Bool)?

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
            guard let key = press.key else {
                rest.insert(press)
                continue
            }
            // 1) 欄が空で変換中でないときは、素の数字・↑↓・Space・Enter を先に親(選択肢)へ。Esc は常に親へ
            if !ime.isComposing, let plain = Self.plainKey(for: key),
               plain == .escape || (text ?? "").isEmpty, onPlainKey?(plain) == true {
                swallowedPresses.insert(press)
                suppressNextInsert = key.characters.isEmpty ? nil : key.characters
                continue
            }
            // 2) IME(変換中の Enter は確定、Esc は取り消し)
            if let imeKey = Self.imeKey(for: key), consume(imeKey) {
                swallowedPresses.insert(press)
                // 消費した押下から insertText が来ても二重に扱わない(pressesEnded で解除)
                suppressNextInsert = key.characters.isEmpty ? nil : key.characters
                continue
            }
            // 3) 素の Enter → 送信(カーソルは欄に残す)。insertText に "\n" で来る分も pressesEnded まで捨てる
            if !ime.isComposing, Self.plainKey(for: key) == .enter, let onSubmit {
                swallowedPresses.insert(press)
                suppressNextInsert = "\n"
                onSubmit()
                continue
            }
            // 4) 修飾キーつきのショートカット(keyCommands で先に取れなかった OS 差の保険)
            if let binding = ComposerKeyBinding.match(input: Self.bindingInput(for: key), modifiers: key.modifierFlags),
               onBinding?(binding) == true {
                swallowedPresses.insert(press)
                suppressNextInsert = key.characters.isEmpty ? nil : key.characters
                continue
            }
            rest.insert(press)
        }
        if !rest.isEmpty {
            super.pressesBegan(rest, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(swallowedPresses)
        swallowedPresses.subtract(presses)
        suppressNextInsert = nil
        if !rest.isEmpty {
            super.pressesEnded(rest, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(swallowedPresses)
        swallowedPresses.subtract(presses)
        suppressNextInsert = nil
        if !rest.isEmpty {
            super.pressesCancelled(rest, with: event)
        }
    }

    /// 編集中だけ矢印・Esc・Tab・F6〜F10 をシステムより先に受け取る(UIKeyCommand は pressesBegan より優先される)
    override var keyCommands: [UIKeyCommand]? {
        guard ime.mode == .kana, ime.isComposing else {
            return bindingKeyCommands + (super.keyCommands ?? [])
        }
        let commands: [(String, UIKeyModifierFlags, Selector)] = [
            (UIKeyCommand.inputUpArrow, [], #selector(imeUp)),
            (UIKeyCommand.inputDownArrow, [], #selector(imeDown)),
            (UIKeyCommand.inputLeftArrow, [], #selector(imeLeft)),
            (UIKeyCommand.inputRightArrow, [], #selector(imeRight)),
            (UIKeyCommand.inputEscape, [], #selector(imeEscape)),
            ("\t", [], #selector(imeTab)),
            ("\t", .shift, #selector(imeShiftTab)),
            (UIKeyCommand.f6, [], #selector(imeF6)),
            (UIKeyCommand.f7, [], #selector(imeF7)),
            (UIKeyCommand.f8, [], #selector(imeF8)),
            (UIKeyCommand.f9, [], #selector(imeF9)),
            (UIKeyCommand.f10, [], #selector(imeF10)),
        ]
        return commands.map { input, flags, action in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        } + bindingKeyCommands + (super.keyCommands ?? [])
    }

    /// ComposerKeyBinding の表を UIKeyCommand にする(⌘ 長押しの一覧に出る)。onBinding が無ければ空。
    private var bindingKeyCommands: [UIKeyCommand] {
        guard onBinding != nil else { return [] }
        return ComposerKeyBinding.allCases.flatMap { b in
            b.specs.map { spec in
                let command = UIKeyCommand(title: spec.title, action: #selector(composerBinding(_:)), input: spec.input, modifierFlags: spec.modifiers)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
    }

    @objc private func composerBinding(_ command: UIKeyCommand) {
        guard let input = command.input,
              let binding = ComposerKeyBinding.match(input: input, modifiers: command.modifierFlags) else { return }
        _ = onBinding?(binding)
    }

    /// 欄が空のときだけ親に回す素のキー(修飾キーなし)。nil はそれ以外。
    static func plainKey(for key: UIKey) -> ComposerPlainKey? {
        guard key.modifierFlags.intersection([.command, .control, .alternate, .shift]).isEmpty else { return nil }
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: return .enter
        case .keyboardEscape: return .escape
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardSpacebar: return .space
        case .keyboard1, .keypad1: return .digit(1)
        case .keyboard2, .keypad2: return .digit(2)
        case .keyboard3, .keypad3: return .digit(3)
        case .keyboard4, .keypad4: return .digit(4)
        case .keyboard5, .keypad5: return .digit(5)
        case .keyboard6, .keypad6: return .digit(6)
        case .keyboard7, .keypad7: return .digit(7)
        case .keyboard8, .keypad8: return .digit(8)
        case .keyboard9, .keypad9: return .digit(9)
        default: return nil
        }
    }

    /// UIKey → ComposerKeyBinding.match に渡す input(矢印・PageUp/Down は UIKeyCommand の定数、文字は無修飾の文字)
    static func bindingInput(for key: UIKey) -> String {
        switch key.keyCode {
        case .keyboardUpArrow: return UIKeyCommand.inputUpArrow
        case .keyboardDownArrow: return UIKeyCommand.inputDownArrow
        case .keyboardPageUp: return UIKeyCommand.inputPageUp
        case .keyboardPageDown: return UIKeyCommand.inputPageDown
        default: return key.charactersIgnoringModifiers.lowercased()
        }
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
        if let suppressed = suppressNextInsert, suppressed == text {
            // pressesBegan で IME が消費した押下の分。テキストには入れない
            suppressNextInsert = nil
            return
        }
        if text == "\n", onSubmit != nil, !ime.isComposing,
           ProcessInfo.processInfo.systemUptime - lastHardwarePressAt < 0.3 {
            // pressesBegan を通らずに物理 Enter の改行だけが来た(OS 差の保険)。送信扱いにして改行は入れない
            onSubmit?()
            return
        }
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
