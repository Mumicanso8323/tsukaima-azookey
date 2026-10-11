import Foundation

/// 練習文の 1 まとまり(表の 1 出力)と、それを打つキー。
public struct NaginataToken: Equatable, Sendable {
    public let text: String
    public let keys: [Character]
}

/// 薙刀式の練習の純粋なロジック(UI 非依存)。表は NaginataTable(Naginata v18 per eswai/zmk-naginata)。
public enum NaginataPractice {
    /// 出力 → 打つキー。同じ出力が複数あるとき(ほ・ひ・れ)はキーの少ない方。
    private static let reverse: [String: [Character]] = {
        var d: [String: [Character]] = [:]
        for e in NaginataTable.entries {
            let keys = Array(e.keys)
            if let old = d[e.output], old.count <= keys.count { continue }
            d[e.output] = keys
        }
        return d
    }()

    /// 修飾側になるキー(濁点・半濁点・拗音・小書きなどの F J K V M Q H P I と親指 Space)
    private static let modifierKeys: Set<Character> = [" ", "f", "j", "k", "v", "m", "q", "h", "p", "i"]

    /// 文を表の出力に最長一致で分ける。表にない文字があれば nil。
    public static func tokens(for text: String) -> [NaginataToken]? {
        let chars = Array(text)
        var result: [NaginataToken] = []
        var i = 0
        while i < chars.count {
            var found = false
            for len in stride(from: min(3, chars.count - i), through: 1, by: -1) {
                let piece = String(chars[i ..< i + len])
                if let keys = reverse[piece] {
                    result.append(NaginataToken(text: piece, keys: keys))
                    i += len
                    found = true
                    break
                }
            }
            if !found { return nil }
        }
        return result
    }

    /// 配列図で 2 色に塗り分けるための役割。base = 主になるキー、modifier = 同時に押す修飾側。
    public static func roles(for keys: [Character]) -> (base: Set<Character>, modifier: Set<Character>) {
        guard keys.count > 1 else { return (Set(keys), []) }
        var modifier = Set(keys.filter { modifierKeys.contains($0) })
        var base = Set(keys).subtracting(modifier)
        if base.isEmpty, let last = keys.last {
            base = [last]
            modifier.remove(last)
        }
        return (base, modifier)
    }

    /// 練習文(よく使うかなから順に、短いものから)
    public static let sentences: [String] = [
        "いいね。",
        "ありがとう。",
        "おはよう。",
        "こんにちは。",
        "そうですね。",
        "わかりました。",
        "おねがいします。",
        "どうぞよろしく。",
        "これはなんですか。",
        "すこしまってください。",
        "いまからでかけます。",
        "ただいま、かえりました。",
        "きょうはいいてんきです。",
        "あしたはがっこうにいく。",
        "ちょっとやすみます。",
        "ごはんをたべにいこう。",
        "ゆっくりはなしてください。",
        "しゅくだいがおわらない。",
        "じゅぎょうのじゅんびをする。",
        "ぜんぜんわからなかった。",
    ]
}

/// 1 つの練習文の進み具合。打った文字列(確定分 + 編集中)を渡すたびに更新する。
public struct NaginataPracticeProgress: Equatable, Sendable {
    public let target: String
    public let tokens: [NaginataToken]
    /// 先頭から正しく打てた文字数
    public private(set) var matched = 0
    /// 間違いの回数(正しい状態から外れた回数。外れたままの間は増えない)
    public private(set) var errors = 0
    private var mismatching = false

    public init(target: String) {
        self.target = target
        self.tokens = NaginataPractice.tokens(for: target) ?? []
    }

    public var isComplete: Bool { matched >= target.count }

    public mutating func update(typed: String) {
        let t = Array(target)
        let u = Array(typed)
        var n = 0
        while n < t.count, n < u.count, t[n] == u[n] { n += 1 }
        matched = n
        let wrong = n < u.count
        if wrong && !mismatching { errors += 1 }
        mismatching = wrong
    }

    /// 次に打つ 1 まとまり(間違えている間は、直したあとに打つもの)。完了なら nil。
    public var nextToken: NaginataToken? {
        var pos = 0
        for token in tokens {
            let end = pos + token.text.count
            if end > matched { return token }
            pos = end
        }
        return nil
    }
}
