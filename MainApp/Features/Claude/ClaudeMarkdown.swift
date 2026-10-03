import Foundation

enum MDAlign: Equatable, Sendable {
    case none, left, center, right
}

struct MDListItem: Equatable, Sendable {
    var checked: Bool?
    var blocks: [MDBlock]
}

indirect enum MDBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [MDListItem])
    case code(language: String?, code: String)
    case table(header: [String], alignments: [MDAlign], rows: [[String]])
    case quote([MDBlock])
    case rule
    case image(alt: String, source: String)
}

enum ClaudeMarkdown {
    static func parse(_ source: String) -> [MDBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return [] }
        var parser = Parser(lines: normalized.components(separatedBy: "\n"))
        return parser.parse()
    }

    private struct Parser {
        let lines: [String]
        var index = 0

        mutating func parse() -> [MDBlock] { parseBlocks() }

        mutating func parseBlocks() -> [MDBlock] {
            var result: [MDBlock] = []
            while index < lines.count {
                if isBlank(lines[index]) { index += 1; continue }
                if let fence = fenceStart(lines[index]) {
                    result.append(parseFence(fence))
                } else if let heading = heading(lines[index]) {
                    result.append(.heading(level: heading.0, text: heading.1)); index += 1
                } else if isRule(lines[index]) {
                    result.append(.rule); index += 1
                } else if let image = fullLineImage(lines[index]) {
                    result.append(.image(alt: image.0, source: image.1)); index += 1
                } else if isQuote(lines[index]) {
                    result.append(parseQuote())
                } else if let marker = listMarker(lines[index]) {
                    result.append(parseList(marker))
                } else if isTableStart(at: index) {
                    result.append(parseTable())
                } else {
                    result.append(parseParagraph())
                }
            }
            return result
        }

        mutating func parseFence(_ fence: (character: Character, count: Int, language: String?)) -> MDBlock {
            index += 1
            var body: [String] = []
            while index < lines.count {
                if isFenceClose(lines[index], character: fence.character, minimumCount: fence.count) {
                    index += 1
                    break
                }
                body.append(lines[index]); index += 1
            }
            return .code(language: fence.language, code: body.joined(separator: "\n"))
        }

        mutating func parseQuote() -> MDBlock {
            var quoted: [String] = []
            while index < lines.count {
                if let stripped = stripQuote(lines[index]) {
                    quoted.append(stripped); index += 1
                } else if isBlank(lines[index]), index + 1 < lines.count, isQuote(lines[index + 1]) {
                    quoted.append(""); index += 1
                } else { break }
            }
            var parser = Parser(lines: quoted)
            return .quote(parser.parse())
        }

        mutating func parseList(_ first: ListMarker) -> MDBlock {
            let listIndent = first.indent
            let ordered = first.ordered
            let start = first.number ?? 1
            var items: [MDListItem] = []
            while index < lines.count, let marker = listMarker(lines[index]), marker.indent == listIndent, marker.ordered == ordered {
                let prefixWidth = marker.contentStart
                var itemLines = [marker.content]
                index += 1
                while index < lines.count {
                    let line = lines[index]
                    if let next = listMarker(line), next.indent == listIndent { break }
                    if !isBlank(line), leadingSpaces(line) <= listIndent { break }
                    if isBlank(line) { itemLines.append(""); index += 1; continue }
                    itemLines.append(dedent(line, by: min(prefixWidth, leadingSpaces(line))))
                    index += 1
                }
                var nested = Parser(lines: itemLines)
                items.append(MDListItem(checked: marker.checked, blocks: nested.parse()))
            }
            return .list(ordered: ordered, start: start, items: items)
        }

        mutating func parseTable() -> MDBlock {
            let header = tableCells(lines[index])
            let alignments = tableCells(lines[index + 1]).map(tableAlignment)
            index += 2
            var rows: [[String]] = []
            while index < lines.count, hasUnescapedPipe(lines[index]), !isBlank(lines[index]) {
                var row = tableCells(lines[index])
                if row.count < header.count { row.append(contentsOf: repeatElement("", count: header.count - row.count)) }
                if row.count > header.count { row = Array(row.prefix(header.count)) }
                rows.append(row); index += 1
            }
            return .table(header: header, alignments: alignments, rows: rows)
        }

        mutating func parseParagraph() -> MDBlock {
            var paragraph: [String] = []
            while index < lines.count {
                if isBlank(lines[index]) { break }
                if !paragraph.isEmpty && isBlockStart(at: index) { break }
                paragraph.append(lines[index]); index += 1
            }
            return .paragraph(paragraph.joined(separator: "\n"))
        }

        func isBlockStart(at lineIndex: Int) -> Bool {
            let line = lines[lineIndex]
            return fenceStart(line) != nil || heading(line) != nil || isRule(line) || fullLineImage(line) != nil || isQuote(line) || listMarker(line) != nil || isTableStart(at: lineIndex)
        }

        func isTableStart(at lineIndex: Int) -> Bool {
            guard lineIndex + 1 < lines.count, hasUnescapedPipe(lines[lineIndex]) else { return false }
            let header = tableCells(lines[lineIndex])
            let separator = tableCells(lines[lineIndex + 1])
            guard !header.isEmpty, separator.count >= header.count else { return false }
            return separator.prefix(header.count).allSatisfy(isTableSeparator)
        }
    }

    private struct ListMarker {
        let indent: Int
        let ordered: Bool
        let number: Int?
        let contentStart: Int
        let content: String
        let checked: Bool?
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }
    private static func leadingSpaces(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    private static func dedent(_ line: String, by count: Int) -> String { String(line.dropFirst(count)) }

    private static func trimmedLeading(_ line: String) -> Substring { line.drop { $0 == " " || $0 == "\t" } }

    private static func heading(_ line: String) -> (Int, String)? {
        let text = trimmedLeading(line)
        let hashes = text.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), text.count == hashes || text[text.index(text.startIndex, offsetBy: hashes)] == " " else { return nil }
        var content = String(text.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        let closingCount = content.reversed().prefix { $0 == "#" }.count
        let withoutClosingHashes = content.dropLast(closingCount)
        if withoutClosingHashes.count < content.count, withoutClosingHashes.last?.isWhitespace == true {
            content = String(withoutClosingHashes).trimmingCharacters(in: .whitespaces)
        }
        return (hashes, content)
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func fenceStart(_ line: String) -> (character: Character, count: Int, language: String?)? {
        let text = trimmedLeading(line)
        guard let character = text.first, character == "`" || character == "~" else { return nil }
        let count = text.prefix { $0 == character }.count
        guard count >= 3 else { return nil }
        let language = String(text.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        return (character, count, language.isEmpty ? nil : language)
    }

    private static func isFenceClose(_ line: String, character: Character, minimumCount: Int) -> Bool {
        let text = trimmedLeading(line)
        return text.prefix { $0 == character }.count >= minimumCount && text.drop { $0 == character }.allSatisfy { $0.isWhitespace }
    }

    private static func fullLineImage(_ line: String) -> (String, String)? {
        let text = String(line.trimmingCharacters(in: .whitespaces))
        guard text.hasPrefix("!["), let middle = text.range(of: "]("), text.hasSuffix(")") else { return nil }
        let alt = String(text[text.index(text.startIndex, offsetBy: 2)..<middle.lowerBound])
        let source = String(text[middle.upperBound..<text.index(before: text.endIndex)])
        return source.isEmpty ? nil : (alt, source)
    }

    private static func isQuote(_ line: String) -> Bool { stripQuote(line) != nil }
    private static func stripQuote(_ line: String) -> String? {
        let text = trimmedLeading(line)
        guard text.first == ">" else { return nil }
        let remainder = text.dropFirst()
        return String(remainder.first == " " ? remainder.dropFirst() : remainder)
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingSpaces(line)
        let text = line.dropFirst(indent)
        guard !text.isEmpty else { return nil }
        var ordered = false
        var number: Int?
        var markerLength = 0
        if let first = text.first, first == "-" || first == "*" || first == "+" {
            markerLength = 1
        } else {
            let digits = text.prefix { $0.isNumber }
            guard !digits.isEmpty, let punctuation = text.dropFirst(digits.count).first, punctuation == "." || punctuation == ")" else { return nil }
            ordered = true; number = Int(digits); markerLength = digits.count + 1
        }
        let afterMarker = text.dropFirst(markerLength)
        guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
        let content = String(afterMarker.drop { $0 == " " || $0 == "\t" })
        var checked: Bool?
        var visibleContent = content
        if content.hasPrefix("[ ] ") { checked = false; visibleContent = String(content.dropFirst(4)) }
        if content.lowercased().hasPrefix("[x] ") { checked = true; visibleContent = String(content.dropFirst(4)) }
        return ListMarker(indent: indent, ordered: ordered, number: number, contentStart: indent + markerLength + 1, content: visibleContent, checked: checked)
    }

    private static func hasUnescapedPipe(_ line: String) -> Bool {
        var escaped = false
        for character in line {
            if character == "|" && !escaped { return true }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        return false
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if character == "|" && !escaped { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            if character == "|" && escaped {
                if current.last == "\\" { current.removeLast() }
                current.append(character); escaped = false; continue
            }
            current.append(character)
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|") { cells.removeLast() }
        return cells
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        let text = cell.trimmingCharacters(in: .whitespaces)
        var core = text
        if core.hasPrefix(":") { core.removeFirst() }
        if core.hasSuffix(":") { core.removeLast() }
        return core.count >= 3 && core.allSatisfy { $0 == "-" }
    }

    private static func tableAlignment(_ cell: String) -> MDAlign {
        let text = cell.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(":") && text.hasSuffix(":") { return .center }
        if text.hasPrefix(":") { return .left }
        if text.hasSuffix(":") { return .right }
        return .none
    }
}

/// 解析した結果を覚える入れ物(NSCache は複数のスレッドから触れる)
final class ClaudeAttributedBox: @unchecked Sendable {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

enum ClaudeInline {
    private static let cache: NSCache<NSString, ClaudeAttributedBox> = {
        let cache = NSCache<NSString, ClaudeAttributedBox>()
        cache.countLimit = 2_000
        return cache
    }()

    /// 同じ文は何度も描き直されるので、解析(正規表現・Markdown の変換)の結果を覚えておく
    static func attributed(_ source: String) -> AttributedString {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = build(source)
        cache.setObject(ClaudeAttributedBox(value), forKey: key)
        return value
    }

    private static func build(_ source: String) -> AttributedString {
        #if canImport(Darwin)
        let prepared = linkifyRawReferences(in: source)
        var result = (try? AttributedString(markdown: prepared, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        applyLinks(from: references(in: source), to: &result)
        return result
        #else
        return AttributedString(source)
        #endif
    }

    #if canImport(Darwin)
    private static func linkifyRawReferences(in source: String) -> String {
        var output = "", index = source.startIndex, inCode = false
        while index < source.endIndex {
            if source[index] == "`" {
                // `パス` や `URL` だけのインラインコードは、コードの見た目のまま押せるリンクにする(Claude はパスをよく `` で囲む)
                let afterTick = source.index(after: index)
                if !inCode, let close = source[afterTick...].firstIndex(of: "`"), close > afterTick,
                   let target = reference(at: afterTick, in: source), target.end == close {
                    output += "[`\(target.display)`](\(target.url.absoluteString))"
                    index = source.index(after: close); continue
                }
                inCode.toggle(); output.append("`"); index = afterTick; continue
            }
            if source[index] == "[", let close = source[index...].firstIndex(of: "]"), close < source.endIndex, source.index(after: close) < source.endIndex, source[source.index(after: close)] == "(" {
                let end = source[source.index(after: close)...].firstIndex(of: ")") ?? source.endIndex
                let next = end < source.endIndex ? source.index(after: end) : end
                output += String(source[index..<next]); index = next; continue
            }
            if let target = reference(at: index, in: source) {
                if inCode { output += target.display }
                else { output += "[\(target.display)](\(target.url.absoluteString))" }
                index = target.end; continue
            }
            output.append(source[index]); index = source.index(after: index)
        }
        return output
    }

    private static func reference(at index: String.Index, in source: String) -> (display: String, url: URL, end: String.Index)? {
        let rest = source[index...]
        let startsURL = rest.hasPrefix("http://") || rest.hasPrefix("https://")
        let startsPath = rest.hasPrefix("/data/ashwell/") || rest.hasPrefix("/home/ashwell/") || rest.hasPrefix("~/")
        guard startsURL || startsPath else { return nil }
        var end = index
        while end < source.endIndex, !source[end].isWhitespace, !"()\"'`".contains(source[end]) { end = source.index(after: end) }
        let display = String(source[index..<end])
        if startsURL, let url = URL(string: display) { return (display, url, end) }
        let absolute = display.hasPrefix("~/") ? "/home/ashwell/" + String(display.dropFirst(2)) : display
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "/?&=+")
        guard let encoded = String(absolute).addingPercentEncoding(withAllowedCharacters: allowed), let url = URL(string: "tsukaima-file://open?path=\(encoded)") else { return nil }
        return (display, url, end)
    }

    private static func references(in source: String) -> [(display: String, url: URL)] {
        var found: [(display: String, url: URL)] = []
        var index = source.startIndex
        while index < source.endIndex {
            if let reference = reference(at: index, in: source) {
                found.append((reference.display, reference.url))
                index = reference.end
            } else {
                index = source.index(after: index)
            }
        }
        return found
    }

    private static func applyLinks(from references: [(display: String, url: URL)], to value: inout AttributedString) {
        for reference in references {
            let plain = String(value.characters)
            var searchStart = plain.startIndex
            while let match = plain.range(of: reference.display, range: searchStart..<plain.endIndex) {
                let lowerOffset = plain.distance(from: plain.startIndex, to: match.lowerBound)
                let upperOffset = plain.distance(from: plain.startIndex, to: match.upperBound)
                let lower = value.characters.index(value.startIndex, offsetBy: lowerOffset)
                let upper = value.characters.index(value.startIndex, offsetBy: upperOffset)
                value[lower..<upper].link = reference.url
                searchStart = match.upperBound
            }
        }
    }
    #endif
}
