//
//  CandidateBlocklist.swift
//  使い魔azooKey
//
//  「この文字列を含む候補は出さない」リスト。hub から配られる block と、候補の長押しで足したローカル分を合わせて持つ。
//  変換候補・予測候補・補助候補のすべてが ResultModel を通るので、表示直前にここで落とす。
//

import Foundation

public final class CandidateBlocklist: @unchecked Sendable {
    public static let shared = CandidateBlocklist()

    private let lock = NSLock()
    private var hubPatterns: [String] = []
    private var localPatterns: [String] = []
    private var merged: [String] = []

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

    public var patterns: [String] {
        lock.lock(); defer { lock.unlock() }
        return merged
    }

    public func isBlocked(_ text: String) -> Bool {
        Self.isBlocked(text, patterns: patterns)
    }

    /// `text` がどれか 1 つでも(空でない)パターンを含んでいれば true
    public static func isBlocked(_ text: String, patterns: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        return patterns.contains { !$0.isEmpty && text.contains($0) }
    }

    /// テキスト表示の候補だけを対象に、ブロック対象を取り除く(アイコン候補などはそのまま)
    public func filter(_ items: [any ResultViewItemData]) -> [any ResultViewItemData] {
        let patterns = self.patterns
        guard !patterns.isEmpty else { return items }
        return items.filter { item in
            if case .text(let value) = item.label {
                return !Self.isBlocked(value, patterns: patterns)
            }
            return true
        }
    }

    private func rebuild() {
        var seen = Set<String>()
        merged = (hubPatterns + localPatterns)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
