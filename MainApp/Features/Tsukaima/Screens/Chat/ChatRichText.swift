import SwiftUI

/// 返答の簡易表示(Web 版の richText と同じ範囲): ``` で囲んだコード・`コード`・**太字**・見出し・箇条書き・URL だけ整形する。
struct ChatRichText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, b in
                if b.code {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(b.text)
                            .font(.system(.footnote, design: .monospaced))
                            .padding(8)
                    }
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                } else if !b.text.isEmpty {
                    Text(Self.inline(b.text))
                }
            }
        }
    }

    struct Block { var code: Bool; var text: String }

    /// ``` で分けて、奇数番目をコードとして扱う
    static func blocks(_ src: String) -> [Block] {
        let parts = src.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "```")
        return parts.enumerated().map { i, p in
            if i % 2 == 1 {
                // 1 行目の言語名(```swift など)と末尾の改行を落とす
                var lines = p.components(separatedBy: "\n")
                if let first = lines.first, first.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "_" }) {
                    lines.removeFirst()
                }
                if lines.last == "" { lines.removeLast() }
                return Block(code: true, text: lines.joined(separator: "\n"))
            }
            return Block(code: false, text: p.trimmingCharacters(in: .newlines))
        }
    }

    /// 行頭の見出し(# 〜 ####)は太字、箇条書き(- / *)は「•」にしてから、行内の Markdown を解釈し、裸の URL にリンクを張る
    static func inline(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            if let r = line.range(of: #"^#{1,4} "#, options: .regularExpression) {
                let rest = line[r.upperBound...]
                return rest.isEmpty ? "" : "**\(rest)**"
            }
            if let r = line.range(of: #"^\s*[-*] "#, options: .regularExpression) {
                let indent = String(String(line[r]).prefix { $0 == " " || $0 == "\t" })
                return indent + "• " + String(line[r.upperBound...])
            }
            return line
        }
        let joined = lines.joined(separator: "\n")
        var attr = (try? AttributedString(markdown: joined,
                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(joined)
        linkify(&attr)
        return attr
    }

    private static func linkify(_ attr: inout AttributedString) {
        let plain = String(attr.characters)
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let ns = plain as NSString
        for m in det.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, url.scheme == "http" || url.scheme == "https",
                  let sr = Range(m.range, in: plain) else { continue }
            let lower = plain.distance(from: plain.startIndex, to: sr.lowerBound)
            let len = plain.distance(from: sr.lowerBound, to: sr.upperBound)
            let a = attr.characters.index(attr.startIndex, offsetBy: lower)
            let b = attr.characters.index(a, offsetBy: len)
            if attr[a..<b].link == nil { attr[a..<b].link = url }
        }
    }
}
