import AzooKeyUtils
import GameController
import UIKit

/// `pressesBegan` で IME が消費した入力を、後から届く `insertText` と二重に扱わないための
/// 判定。Return の CR/LF 差と pressesEnded 後の配送の両方を UIKit 非依存で扱えるようにする。
struct HardwareIMEInsertSuppression {
    static let window: TimeInterval = 0.3

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func shouldSuppress(text: String, pending: String?, elapsed: TimeInterval) -> Bool {
        guard let pending, elapsed >= 0, elapsed < window else { return false }
        return normalized(text) == normalized(pending)
    }
}

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

    /// FocusGuard の対象にするか(入力欄が画面に 1 つだけの画面で true にする)
    var pinsFocus = false
    /// FocusGuard が「戻してほしい」と見ているか(本人が触ったら true、アプリが意図して外したら false)
    var guardWantsFocus = false
    /// アプリ側のコードが意図して resign する直前に立てる(FocusGuard が戻さない)
    var guardIntentionalResign = false
    /// UI テスト専用: システムが奪った喪失として扱う(本人が閉じたものと見なさない)
    var guardSystemLoss = false

    private var swallowedPresses = Set<UIPress>()
    private var lastHardwarePressAt: TimeInterval = 0
    private var suppressNextInsert: String?

    init(ime: HardwareIMECore) {
        self.ime = ime
        super.init(frame: .zero, textContainer: nil)
        // キーボードの出入りの通知を取りこぼさないよう、最初の入力欄を作る時点で FocusGuard を起こしておく
        _ = FocusGuard.shared
        ime.onStateChange = { [weak self] in self?.onIMEStateChange?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 物理キーボードの日本語変換を使うか(設定がオンで、変換辞書が読めるとき)
    static var conversionEnabled: Bool {
        HardwareIMESettings.enabled && MainActor.assumeIsolated { HardwareIMEConverter.shared.isAvailable }
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
                // Return は UIKit 側で CR/LF が混在し、insertText は pressesEnded の後に
                // 届くこともある。短い時間だけ正規化した値を保留する。
                suppressNextInsert = key.characters.isEmpty ? nil : HardwareIMEInsertSuppression.normalized(key.characters)
            } else {
                // 消費していない押下の前に残った保留は捨てる(本物の改行を落とさない)
                suppressNextInsert = nil
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
        // 設定でオフ・辞書が無いときは変換しない(ただの UITextView として振る舞う)
        guard Self.conversionEnabled else {
            return false
        }
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
        let elapsed = ProcessInfo.processInfo.systemUptime - lastHardwarePressAt
        if HardwareIMEInsertSuppression.shouldSuppress(text: text, pending: suppressNextInsert, elapsed: elapsed) {
            // pressesBegan で IME が消費した押下の分。テキストには入れない
            suppressNextInsert = nil
            return
        }
        if suppressNextInsert != nil, elapsed >= HardwareIMEInsertSuppression.window {
            suppressNextInsert = nil
        }
        let normalizedText = HardwareIMEInsertSuppression.normalized(text)
        if ime.mode == .kana, normalizedText.count == 1, let c = normalizedText.first,
           elapsed < HardwareIMEInsertSuppression.window,
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        FocusGuard.shared.didMoveToWindow(self)
    }

    override func resignFirstResponder() -> Bool {
        apply(ime.commitAll())
        HardwareIMEConverter.shared.flushLearning()
        return super.resignFirstResponder()
    }
}
