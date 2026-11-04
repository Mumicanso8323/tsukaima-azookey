import Foundation

/// 薙刀式の出力。
public enum NaginataOutput: Equatable, Sendable {
    /// かな・記号の文字列
    case text(String)
    /// 単独の Space(他のキーと組み合わさなかった親指シフト)
    case space
}

/// 薙刀式の判定エンジン。時刻を引数で受けるので単体テストできる(UIKit 非依存)。
/// 表は Naginata v18 per eswai/zmk-naginata (reference table; keymap draft
/// /data/ashwell/life/keyboard-layouts/scoring/keymaps/naginata_corne/BUILD.md; revision pin 6d852bf9b4)。
/// キーは QWERTY の文字(a-z ; , . /)と " "(Space = 親指シフト)。
public final class NaginataEngine {
    /// 同時押しとみなす窓(秒)。参照実装の MIN_OVERLAP は 50ms。
    public static let defaultWindow: TimeInterval = 0.07
    /// 押しっぱなしで連続シフトになるキー(濁音の F/J と親指 Space)
    public static let continuousShiftKeys: Set<Character> = [" ", "f", "j"]

    public let window: TimeInterval
    private let table: [Set<Character>: String]
    private let sets: [Set<Character>]

    private var down = Set<Character>()
    private var pending: [(key: Character, time: TimeInterval)] = []
    private var shifts = Set<Character>()
    private var spaceAlone = false

    public init(window: TimeInterval = NaginataEngine.defaultWindow) {
        self.window = window
        var t: [Set<Character>: String] = [:]
        for e in NaginataTable.entries {
            t[Set(e.keys)] = e.output
        }
        self.table = t
        self.sets = Array(t.keys)
    }

    public static func isNaginataKey(_ c: Character) -> Bool {
        let letters = "abcdefghijklmnopqrstuvwxyz;,./ "
        return letters.contains(c)
    }

    public func keyDown(_ k: Character, at time: TimeInterval) -> [NaginataOutput] {
        guard Self.isNaginataKey(k), !down.contains(k) else { return [] }
        var out = resolve(at: time, forceAll: false)
        down.insert(k)
        if k == " " { spaceAlone = true }
        pending.append((k, time))
        out += resolve(at: time, forceAll: false)
        return out
    }

    public func keyUp(_ k: Character, at time: TimeInterval) -> [NaginataOutput] {
        guard Self.isNaginataKey(k) else { return [] }
        var out = resolve(at: time, forceAll: false)
        let wasPending = pending.contains { $0.key == k }
        if wasPending {
            out += resolve(at: time, forceAll: true, releasing: k)
        }
        down.remove(k)
        shifts.remove(k)
        if k == " " {
            if spaceAlone && !pending.contains(where: { $0.key == " " }) {
                out.append(.space)
            }
            spaceAlone = false
        }
        return out
    }

    /// 押下状態をすべて捨てる(フォーカス喪失で離した通知が来ないとき)
    public func reset() {
        down.removeAll()
        pending.removeAll()
        shifts.removeAll()
        spaceAlone = false
    }

    /// 時間切れの確定
    public func flush(at time: TimeInterval) -> [NaginataOutput] {
        resolve(at: time, forceAll: false)
    }

    /// 待っているものをすべて確定する(Enter など別のキーの前に)
    public func flushAll(at time: TimeInterval) -> [NaginataOutput] {
        resolve(at: time, forceAll: true)
    }

    public func nextDeadline() -> TimeInterval? {
        guard let first = pending.first else { return nil }
        if holdsAlone(first.key) { return nil }
        return first.time + window
    }

    // MARK: - 判定

    private func holdsAlone(_ key: Character) -> Bool {
        pending.count == 1 && shifts.isEmpty && Self.continuousShiftKeys.contains(key) && down.contains(key)
    }

    private func resolve(at time: TimeInterval, forceAll: Bool, releasing: Character? = nil) -> [NaginataOutput] {
        var out: [NaginataOutput] = []
        while let first = pending.first {
            var cand = shifts
            for p in pending { cand.insert(p.key) }
            let expired = forceAll || (time >= first.time + window && !holdsAlone(first.key))
            if !expired && sets.contains(where: { $0.count > cand.count && $0.isSuperset(of: cand) }) {
                break
            }
            // 最長一致(いちばん古い未確定キーを含むもの)
            var best: Set<Character>?
            for s in sets where s.contains(first.key) && s.isSubset(of: cand) {
                if best == nil || s.count > best!.count { best = s }
            }
            guard let chosen = best, let text = table[chosen] else {
                pending.removeFirst()
                if first.key == " " {
                    if down.contains(" ") && releasing != " " {
                        shifts.insert(" ")
                    } else if spaceAlone {
                        out.append(.space)
                        spaceAlone = false
                    }
                }
                continue
            }
            out.append(.text(text))
            pending.removeAll { chosen.contains($0.key) }
            for key in chosen where Self.continuousShiftKeys.contains(key) && down.contains(key) && key != releasing {
                shifts.insert(key)
            }
            if chosen.contains(" ") { spaceAlone = false }
        }
        return out
    }
}
