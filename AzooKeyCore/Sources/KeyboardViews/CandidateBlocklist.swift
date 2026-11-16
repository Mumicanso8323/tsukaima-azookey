//
//  CandidateBlocklist.swift
//  使い魔azooKey
//
//  候補を出さないリスト。hub から配られる block は「この文字列を含む候補」を落とす(部分一致)。
//  候補の長押しで足したローカル分は、その候補そのもの(完全一致)だけを落とす。
//  (2026-11-16 本人『サンを出さないようにしたらサンを含むあらゆる言葉も出なくなって最悪』)
//  変換候補・予測候補・補助候補のすべてが ResultModel を通るので、表示直前にここで落とす。
//

import Foundation

public final class CandidateBlocklist: @unchecked Sendable {
    public static let shared = CandidateBlocklist()

    private let lock = NSLock()
    private var hubPatterns: [String] = []
    private var localPatterns: [String] = []
    private var merged: [String] = []
    private var localExact: Set<String> = []

    public init() {}

    /// hub 側(GET /api/ime/dict の block)を差し替える
    public func setHubPatterns(_ patterns: [String]) {
        lock.lock(); defer { lock.unlock() }
        hubPatterns = patterns
        rebuild()
    }

    /// 端末ローカル(長押しで「出さない」にしたもの)を差し替える
    public func setLocalPatterns(_ patterns: [String]) {
        lock.lock(); defer { lock.unlock() }
        localPatterns = patterns
        rebuild()
    }

    /// 部分一致で落とすパターン(hub 由来)
    public var patterns: [String] {
        lock.lock(); defer { lock.unlock() }
        return merged
    }

    /// 完全一致で落とす候補(長押しで足したローカル分)
    public var exactTexts: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return localExact
    }

    public func isBlocked(_ text: String) -> Bool {
        Self.isBlocked(text, patterns: patterns, exact: exactTexts)
    }

    public static func isBlocked(_ text: String, patterns: [String], exact: Set<String>) -> Bool {
        guard !text.isEmpty else { return false }
        if exact.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return true }
        return isBlocked(text, patterns: patterns)
    }

    /// `text` がどれか 1 つでも(空でない)パターンを含んでいれば true
    public static func isBlocked(_ text: String, patterns: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        return patterns.contains { !$0.isEmpty && text.contains($0) }
    }

    /// テキスト表示の候補だけを対象に、ブロック対象を取り除く(アイコン候補などはそのまま)
    public func filter(_ items: [any ResultViewItemData]) -> [any ResultViewItemData] {
        let patterns = self.patterns
        let exact = self.exactTexts
        guard !patterns.isEmpty || !exact.isEmpty else { return items }
        return items.filter { item in
            if case .text(let value) = item.label {
                return !Self.isBlocked(value, patterns: patterns, exact: exact)
            }
            return true
        }
    }

    private func rebuild() {
        var seen = Set<String>()
        merged = hubPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        localExact = Set(localPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }
}
