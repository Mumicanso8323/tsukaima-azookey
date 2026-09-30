import Foundation
import KanaKanjiConverterModule

/// ハードウェア(Bluetooth)キーボードで打った 1 キーを、IME の操作として抽象化したもの。
/// UIKit の UIPress からの変換は本体アプリ側(HardwareIMETextView)で行う。
public enum HardwareIMEKey: Equatable, Sendable {
    /// 印字可能な 1 文字(修飾キー無し、または Shift のみ)
    case character(Character)
    case space
    case shiftSpace
    case enter
    case escape
    case tab
    case shiftTab
    case backspace
    case deleteForward
    case up
    case down
    case left
    case right
    /// F6 ひらがな / F7 カタカナ / F8 半角カタカナ / F9 全角英数 / F10 半角英数
    case f6, f7, f8, f9, f10
    /// かな⇔英数の切り替え(Caps Lock・Ctrl+Space など)
    case toggleMode
    /// かなキー(JIS の LANG1)
    case toKana
    /// 英数キー(JIS の LANG2)
    case toAlnum
}

/// IME がテキストビューに要求する操作。順番どおりに適用する。
public enum HardwareIMEEffect: Equatable, Sendable {
    /// 編集中の文字列(下線つきの marked text)を差し替える。cursor は marked text 内の文字位置。
    case setMarked(String, cursor: Int)
    /// marked text をこの文字列で確定する(marked を置き換えて unmark)
    case commit(String)
    /// marked text を捨てる
    case clearMarked
}

public struct HardwareIMEResult: Equatable, Sendable {
    /// false のときはキーを IME が消費しなかった(テキストビューが通常どおり処理する)
    public var handled: Bool
    public var effects: [HardwareIMEEffect]

    public static let passThrough = HardwareIMEResult(handled: false, effects: [])
    public static func handled(_ effects: [HardwareIMEEffect] = []) -> HardwareIMEResult {
        .init(handled: true, effects: effects)
    }
}

/// 変換器との接点。本体アプリでは KanaKanjiConverter を包み、テストでは固定の候補を返す。
@MainActor
public protocol HardwareIMEConversionProvider: AnyObject {
    /// 編集中の文字列(カーソルまで)に対する候補。先頭がもっとも良い候補。
    func candidates(for composing: ComposingText, leftContext: String) -> [Candidate]
    /// 候補を確定した。compositionEnded = true なら編集中の文字列が空になった(学習を確定してよい)。
    func didComplete(_ candidate: Candidate, compositionEnded: Bool)
    /// 変換せずに終えた(無変換確定・取り消し)。変換器の一時状態を捨てる。
    func didCancel()
}

/// ハードウェアキーボード用のかな漢字変換の状態機械。
/// ローマ字入力 → ComposingText、Space で変換・候補送り、Enter で確定、Esc で戻す/取り消し。
/// UIKit にも SwiftUI にも依存しない(azooKeyTests で単体テストできる)。
@MainActor
public final class HardwareIMECore {
    public enum Mode: Equatable, Sendable {
        case kana
        case alnum
    }

    public private(set) var mode: Mode
    public private(set) var composing = ComposingText()
    public private(set) var candidates: [Candidate] = []
    /// nil = まだ変換していない(ひらがなのまま表示)。
    public private(set) var selectedIndex: Int?
    /// F6〜F10 で作った固定表示(ひらがな・カタカナ・英数)。nil なら通常表示。
    public private(set) var specialText: String?

    private let provider: any HardwareIMEConversionProvider
    private let leftContext: () -> String
    /// 状態が変わるたびに呼ばれる(候補バーの再描画用)
    public var onStateChange: (@MainActor () -> Void)?

    public init(provider: any HardwareIMEConversionProvider, initialMode: Mode = .kana, leftContext: @escaping () -> String = { "" }) {
        self.provider = provider
        self.mode = initialMode
        self.leftContext = leftContext
    }

    public var isComposing: Bool { !composing.isEmpty }
    public var isConverting: Bool { selectedIndex != nil }

    /// いま marked text として見せるべき文字列
    public var displayText: String {
        if let specialText {
            return specialText
        }
        if let selectedIndex, candidates.indices.contains(selectedIndex) {
            let candidate = candidates[selectedIndex]
            var rest = composing
            rest.prefixComplete(composingCount: candidate.composingCount)
            return candidate.text + rest.convertTarget
        }
        return composing.convertTarget
    }

    /// marked text 内のカーソル位置(文字数)。候補表示中は候補の直後(未変換の残りの手前)。
    public var displayCursor: Int {
        if let specialText {
            return specialText.count
        }
        if let selectedIndex, candidates.indices.contains(selectedIndex) {
            return candidates[selectedIndex].text.count
        }
        return composing.convertTargetCursorPosition
    }

    // MARK: - 入力

    public func handle(_ key: HardwareIMEKey) -> HardwareIMEResult {
        switch key {
        case .toggleMode:
            return switchMode(mode == .kana ? .alnum : .kana)
        case .toKana:
            return switchMode(.kana)
        case .toAlnum:
            return switchMode(.alnum)
        default:
            break
        }
        guard mode == .kana else {
            return .passThrough
        }
        switch key {
        case .character(let c):
            return insert(c)
        case .space, .down, .tab:
            return isComposing ? moveSelection(+1) : .passThrough
        case .shiftSpace, .up, .shiftTab:
            return isComposing ? moveSelection(-1) : .passThrough
        case .enter:
            return isComposing ? .handled(commitCurrent()) : .passThrough
        case .escape:
            return escape()
        case .backspace:
            return backspace()
        case .deleteForward:
            guard isComposing else { return .passThrough }
            if selectedIndex != nil || specialText != nil {
                return revertToRaw()
            }
            composing.deleteForwardFromCursorPosition(count: 1)
            return afterEdit()
        case .left:
            return horizontal(-1)
        case .right:
            return horizontal(+1)
        case .f6:
            return special(hiragana(rawKana()))
        case .f7:
            return special(katakana(rawKana()))
        case .f8:
            return special(halfWidthKatakana(rawKana()))
        case .f9:
            return special(fullWidth(rawRomaji()))
        case .f10:
            return special(rawRomaji())
        case .toggleMode, .toKana, .toAlnum:
            return .passThrough
        }
    }

    /// 候補バーのタップなど、番号指定で確定する
    public func commitCandidate(at index: Int) -> [HardwareIMEEffect] {
        guard candidates.indices.contains(index) else {
            return []
        }
        selectedIndex = index
        specialText = nil
        return commitCurrent()
    }

    /// フォーカスを失うときなど: 編集中のものをそのまま確定して空にする
    public func commitAll() -> [HardwareIMEEffect] {
        guard isComposing else {
            return []
        }
        return commitCurrent()
    }

    /// 編集中のものを捨てる(画面を離れるときなど)
    public func cancelAll() -> [HardwareIMEEffect] {
        guard isComposing else {
            return []
        }
        resetComposition()
        provider.didCancel()
        notify()
        return [.clearMarked]
    }

    // MARK: - 各操作

    private func switchMode(_ newMode: Mode) -> HardwareIMEResult {
        var effects: [HardwareIMEEffect] = []
        if isComposing {
            effects = commitCurrent()
        }
        mode = newMode
        notify()
        return .handled(effects)
    }

    /// かなモードで記号キーを日本語の記号にする(ローマ字テーブルには無いので IME 側で持つ)
    public static let punctuation: [Character: String] = [
        ",": "、", ".": "。", "!": "！", "?": "？", "[": "「", "]": "」", "~": "〜", "/": "・",
    ]

    private func insert(_ c: Character) -> HardwareIMEResult {
        var effects: [HardwareIMEEffect] = []
        if c == "-", isComposing {
            // 長音は編集中の文字列に足す(「らーめん」)
            if selectedIndex != nil || specialText != nil {
                effects = commitCurrent()
            }
            composing.insertAtCursorPosition("ー", inputStyle: .direct)
            return .handled(effects + afterEdit().effects)
        }
        if let mapped = Self.punctuation[c] {
            // 「、」「。」は編集中のものを確定してから入れる
            if isComposing {
                effects = commitCurrent()
            }
            return .handled(effects + [.commit(mapped)])
        }
        if composing.isEmpty {
            guard c.isLetter, c.isASCII else {
                // 数字や他の記号、既に日本語になっている文字(OS 側の IME の出力)はそのまま通す
                return .passThrough
            }
            // 大文字は英語をそのまま打ちたい合図(Shift+英字)。編集中でなければ素通し
            if c.isUppercase {
                return .passThrough
            }
        } else if selectedIndex != nil || specialText != nil {
            // 変換中に次の文字を打ったら、いま見えているものを確定してから続ける
            effects = commitCurrent()
        }
        let ch: Character = (c.isLetter && c.isASCII) ? Character(c.lowercased()) : c
        composing.insertAtCursorPosition(String(ch), inputStyle: .roman2kana)
        return .handled(effects + afterEdit().effects)
    }

    private func afterEdit() -> HardwareIMEResult {
        specialText = nil
        selectedIndex = nil
        if composing.isEmpty {
            resetComposition()
            provider.didCancel()
            notify()
            return .handled([.clearMarked])
        }
        refreshCandidates()
        notify()
        return .handled([.setMarked(displayText, cursor: displayCursor)])
    }

    private func refreshCandidates() {
        candidates = provider.candidates(for: composing.prefixToCursorPosition(), leftContext: leftContext())
    }

    private func moveSelection(_ delta: Int) -> HardwareIMEResult {
        specialText = nil
        if candidates.isEmpty {
            refreshCandidates()
        }
        guard !candidates.isEmpty else {
            notify()
            return .handled([.setMarked(displayText, cursor: displayCursor)])
        }
        if let current = selectedIndex {
            selectedIndex = (current + delta + candidates.count) % candidates.count
        } else {
            selectedIndex = delta > 0 ? 0 : candidates.count - 1
        }
        notify()
        return .handled([.setMarked(displayText, cursor: displayCursor)])
    }

    private func horizontal(_ delta: Int) -> HardwareIMEResult {
        guard isComposing else {
            return .passThrough
        }
        if selectedIndex != nil {
            return moveSelection(delta)
        }
        if specialText != nil {
            return .handled([])
        }
        _ = composing.moveCursorFromCursorPosition(count: delta)
        refreshCandidates()
        notify()
        return .handled([.setMarked(displayText, cursor: displayCursor)])
    }

    private func escape() -> HardwareIMEResult {
        guard isComposing else {
            return .passThrough
        }
        if selectedIndex != nil || specialText != nil {
            return revertToRaw()
        }
        resetComposition()
        provider.didCancel()
        notify()
        return .handled([.clearMarked])
    }

    private func backspace() -> HardwareIMEResult {
        guard isComposing else {
            return .passThrough
        }
        if selectedIndex != nil || specialText != nil {
            return revertToRaw()
        }
        composing.deleteBackwardFromCursorPosition(count: 1)
        return afterEdit()
    }

    private func revertToRaw() -> HardwareIMEResult {
        selectedIndex = nil
        specialText = nil
        notify()
        return .handled([.setMarked(displayText, cursor: displayCursor)])
    }

    private func special(_ text: String) -> HardwareIMEResult {
        guard isComposing else {
            return .passThrough
        }
        selectedIndex = nil
        specialText = text
        notify()
        return .handled([.setMarked(displayText, cursor: displayCursor)])
    }

    /// いま見えているものを確定する。候補なら学習に回し、残りがあれば編集を続ける。
    private func commitCurrent() -> [HardwareIMEEffect] {
        if let specialText {
            self.specialText = nil
            resetComposition()
            provider.didCancel()
            notify()
            return [.commit(specialText)]
        }
        guard let index = selectedIndex, candidates.indices.contains(index) else {
            let raw = rawKana()
            resetComposition()
            provider.didCancel()
            notify()
            return [.commit(raw)]
        }
        let candidate = candidates[index]
        composing.prefixComplete(composingCount: candidate.composingCount)
        selectedIndex = nil
        if composing.isEmpty {
            provider.didComplete(candidate, compositionEnded: true)
            resetComposition()
            notify()
            return [.commit(candidate.text)]
        }
        provider.didComplete(candidate, compositionEnded: false)
        refreshCandidates()
        notify()
        return [.commit(candidate.text), .setMarked(displayText, cursor: displayCursor)]
    }

    private func resetComposition() {
        composing.stopComposition()
        candidates = []
        selectedIndex = nil
        specialText = nil
    }

    private func notify() {
        onStateChange?()
    }

    // MARK: - 文字列の作り直し(F6〜F10・無変換確定)

    /// 変換せずに確定するときのひらがな。末尾の「n」は「ん」にする(「kan」→「かん」)。
    public func rawKana() -> String {
        Self.normalizeTrailingN(composing.convertTarget)
    }

    /// 打ったローマ字そのもの(F10 用)
    public func rawRomaji() -> String {
        String(composing.input.compactMap { element -> Character? in
            switch element.piece {
            case .character(let c): c
            case .key(intention: _, input: let c, modifiers: _): c
            case .compositionSeparator: nil
            }
        })
    }

    static func normalizeTrailingN(_ text: String) -> String {
        text.hasSuffix("n") ? String(text.dropLast()) + "ん" : text
    }

    private func hiragana(_ s: String) -> String {
        s.applyingTransform(.hiraganaToKatakana, reverse: true) ?? s
    }

    private func katakana(_ s: String) -> String {
        s.applyingTransform(.hiraganaToKatakana, reverse: false) ?? s
    }

    private func halfWidthKatakana(_ s: String) -> String {
        katakana(s).applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? katakana(s)
    }

    private func fullWidth(_ s: String) -> String {
        s.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? s
    }
}
