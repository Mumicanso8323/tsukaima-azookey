import Foundation

/// 英数(Lang2 = HID 0x91)・かな(Lang1 = HID 0x90)。iOS は IME の切り替えに使い、Web ページへは渡さない。
/// アプリ側で受けて、ページの window へ KeyboardEvent として注入する。
enum LangKey: Int, CaseIterable, Sendable {
    case lang1 = 0x90
    case lang2 = 0x91

    var code: String { self == .lang1 ? "Lang1" : "Lang2" }
}

enum LangKeyPhase: Sendable {
    case down
    case up
}

/// 押下・離上を、ページへ渡す JS の「順序つきの列」にする純ロジック(UIKit / WebKit に依存しない)。
/// - 1 本だけ評価中にして、順序を入れ替えない。
/// - 評価に失敗したものは先頭に残し、pageReady() で同じものから再送する(keyup を落とさない)。
/// - 押したままのキーは cancelAll() で keyup を積む(画面が消える・アプリが非アクティブになる・押下が中断される)。
/// - 押したままの自動リピート(同じキーの down の再来)は、ページに再送しない(keydown は 1 回だけ)。
struct LangKeyEventQueue {
    private(set) var down: Set<LangKey> = []
    private(set) var pending: [String] = []
    private(set) var inFlight = false
    /// 評価に失敗して、pageReady を待っている
    private(set) var stalled = false

    static func script(type: String, key: LangKey) -> String {
        "window.dispatchEvent(new KeyboardEvent('\(type)', {code:'\(key.code)', key:'\(key.code)', bubbles:true}))"
    }

    /// 押下・離上を受ける。このキーを消費する(super に渡さない)なら true。Lang1 / Lang2 以外は false で何も積まない。
    @discardableResult
    mutating func press(usage: Int, phase: LangKeyPhase) -> Bool {
        guard let key = LangKey(rawValue: usage) else { return false }
        switch phase {
        case .down:
            if down.insert(key).inserted {
                pending.append(Self.script(type: "keydown", key: key))
            }
        case .up:
            if down.remove(key) != nil {
                pending.append(Self.script(type: "keyup", key: key))
            }
        }
        return true
    }

    /// 押したままのキーすべてに keyup を積み、押下の集合を空にする。
    mutating func cancelAll() {
        for key in LangKey.allCases where down.contains(key) {
            pending.append(Self.script(type: "keyup", key: key))
        }
        down.removeAll()
    }

    /// 評価を始める。返した JS を evaluate し、終わったら complete(success:) を呼ぶ。評価中・停止中・空なら nil。
    mutating func next() -> String? {
        guard !inFlight, !stalled, let head = pending.first else { return nil }
        inFlight = true
        return head
    }

    /// 評価の結果。成功なら先頭を捨てる。失敗なら先頭を残して止まる(pageReady で再開)。
    mutating func complete(success: Bool) {
        guard inFlight else { return }
        inFlight = false
        if success {
            pending.removeFirst()
        } else {
            stalled = true
        }
    }

    /// ページの読み込みが終わった。失敗で止まっていたら再開できるようにする。
    mutating func pageReady() {
        stalled = false
    }
}
