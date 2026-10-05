import Foundation

enum CodeTokenKind: Equatable, Sendable {
    case plain, keyword, string, comment, number, type, function
}

struct CodeToken: Equatable, Sendable {
    let range: Range<String.Index>
    let kind: CodeTokenKind
}

enum ClaudeCodeHighlighter {
    static func tokens(_ code: String, language: String?) -> [CodeToken] {
        var lexer = Lexer(code: code, language: language?.lowercased() ?? "")
        return lexer.scan()
    }

    private struct Lexer {
        let code: String
        let language: String
        var result: [CodeToken] = []
        var index: String.Index
        var lineStart: Bool = true

        init(code: String, language: String) {
            self.code = code
            self.language = language
            self.index = code.startIndex
        }

        mutating func scan() -> [CodeToken] {
            while index < code.endIndex {
                let start = index
                let character = code[index]
                if isDiff, lineStart, (character == "+" || character == "-") {
                    consumeLine(kind: character == "+" ? .string : .keyword)
                } else if let opener = commentOpener(at: index) {
                    consumeComment(opener: opener)
                } else if character == "\"" || character == "'" || (isSwift && character == "#" && nextCharacter() == "\"") {
                    consumeString()
                } else if character.isNumber {
                    consumeNumber()
                } else if isIdentifierStart(character) {
                    consumeIdentifier()
                } else {
                    advance()
                }
                if start == index { advance() }
            }
            return result
        }

        private var isSwift: Bool { language == "swift" }
        private var isDiff: Bool { language == "diff" }
        private var isShell: Bool { ["bash", "sh", "zsh", "shell", "console"].contains(language) }
        private var isPython: Bool { language == "python" }
        private var isSQL: Bool { language == "sql" }
        private var isHTML: Bool { ["html", "xml"].contains(language) }
        private var isCSS: Bool { language == "css" }

        mutating func consumeLine(kind: CodeTokenKind) {
            let start = index
            while index < code.endIndex, code[index] != "\n" { advance() }
            append(start..<index, kind)
        }

        mutating func consumeComment(opener: CommentOpener) {
            let start = index
            switch opener {
            case .line:
                while index < code.endIndex, code[index] != "\n" { advance() }
            case .block(let close):
                advance(by: opener.length)
                while index < code.endIndex {
                    if code[index...].hasPrefix(close) { advance(by: close.count); break }
                    advance()
                }
            }
            append(start..<index, .comment)
        }

        mutating func consumeString() {
            let start = index
            var rawHashes = 0
            if isSwift && code[index] == "#" {
                while index < code.endIndex, code[index] == "#" { rawHashes += 1; advance() }
            }
            guard index < code.endIndex else { append(start..<index, .string); return }
            let quote = code[index]
            let triple = code[index...].hasPrefix(String(repeating: String(quote), count: 3))
            advance(by: triple ? 3 : 1)
            while index < code.endIndex {
                if !triple && code[index] == "\\" { advance(); if index < code.endIndex { advance() }; continue }
                if triple && code[index...].hasPrefix(String(repeating: String(quote), count: 3)) {
                    advance(by: 3); break
                }
                if !triple && code[index] == quote { advance(); break }
                advance()
            }
            if rawHashes > 0 { for _ in 0..<rawHashes where index < code.endIndex && code[index] == "#" { advance() } }
            append(start..<index, .string)
        }

        mutating func consumeNumber() {
            let start = index
            while index < code.endIndex {
                let c = code[index]
                guard c.isNumber || c.isLetter || c == "." || c == "_" || c == "x" || c == "X" else { break }
                advance()
            }
            append(start..<index, .number)
        }

        mutating func consumeIdentifier() {
            let start = index
            while index < code.endIndex, isIdentifierPart(code[index]) { advance() }
            let word = String(code[start..<index])
            if keyword(word) { append(start..<index, .keyword); return }
            if typeWord(word) || word.first?.isUppercase == true { append(start..<index, .type); return }
            var lookahead = index
            while lookahead < code.endIndex, code[lookahead].isWhitespace && code[lookahead] != "\n" { lookahead = code.index(after: lookahead) }
            if lookahead < code.endIndex, code[lookahead] == "(" { append(start..<index, .function) }
        }

        func keyword(_ word: String) -> Bool {
            switch language {
            case "swift": return ["import", "let", "var", "func", "struct", "class", "enum", "protocol", "extension", "if", "else", "guard", "return", "for", "while", "switch", "case", "default", "break", "continue", "async", "await", "throws", "throw", "try", "private", "public", "internal", "static", "actor", "where", "in", "is", "as", "nil", "true", "false"].contains(word)
            case "python": return ["def", "class", "import", "from", "as", "if", "elif", "else", "for", "while", "return", "yield", "try", "except", "finally", "with", "lambda", "async", "await", "True", "False", "None", "and", "or", "not", "in", "is", "pass", "break", "continue"].contains(word)
            case "javascript", "js", "jsx", "typescript", "ts", "tsx": return ["const", "let", "var", "function", "class", "import", "export", "from", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "new", "async", "await", "throw", "try", "catch", "finally", "true", "false", "null", "undefined", "interface", "type", "extends", "implements", "public", "private"].contains(word)
            case "go": return ["package", "import", "func", "var", "const", "type", "struct", "interface", "return", "if", "else", "for", "range", "go", "defer", "select", "case", "switch", "map", "chan", "true", "false", "nil"].contains(word)
            case "rust": return ["fn", "let", "mut", "struct", "enum", "impl", "trait", "use", "mod", "pub", "crate", "self", "Self", "return", "if", "else", "match", "loop", "while", "for", "in", "async", "await", "move", "where", "true", "false"].contains(word)
            case "c", "cpp", "objc": return ["int", "void", "char", "float", "double", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "struct", "class", "public", "private", "static", "const", "include", "define", "nil", "NULL"].contains(word)
            case "sql": return ["SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "AND", "OR", "NOT", "NULL"].contains(word.uppercased())
            case "json", "yaml", "yml": return ["true", "false", "null", "True", "False", "None"].contains(word)
            default: return isShell && ["if", "then", "fi", "for", "in", "do", "done", "case", "esac", "function", "local", "export", "return"].contains(word)
            }
        }

        func typeWord(_ word: String) -> Bool {
            ["String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Optional", "Any", "Void", "Result", "Error"].contains(word)
        }

        func commentOpener(at position: String.Index) -> CommentOpener? {
            let rest = code[position...]
            if isShell || isPython || language == "yaml" || language == "yml", rest.hasPrefix("#") { return .line }
            if isSQL, rest.hasPrefix("--") { return .line }
            if isHTML, rest.hasPrefix("<!--") { return .block("-->") }
            if !isHTML && rest.hasPrefix("//") { return .line }
            if rest.hasPrefix("/*") { return .block("*/") }
            return nil
        }

        mutating func append(_ range: Range<String.Index>, _ kind: CodeTokenKind) {
            guard range.lowerBound < range.upperBound else { return }
            result.append(CodeToken(range: range, kind: kind))
        }

        mutating func advance() {
            guard index < code.endIndex else { return }
            lineStart = code[index] == "\n"
            index = code.index(after: index)
        }

        mutating func advance(by count: Int) { for _ in 0..<count where index < code.endIndex { advance() } }
        func nextCharacter() -> Character? { let next = code.index(after: index); return next < code.endIndex ? code[next] : nil }
        func isIdentifierStart(_ character: Character) -> Bool { character == "_" || character.isLetter }
        func isIdentifierPart(_ character: Character) -> Bool { isIdentifierStart(character) || character.isNumber }
    }

    private enum CommentOpener {
        case line
        case block(String)
        var length: Int { switch self { case .line: return 2; case .block(let close): return close == "-->" ? 4 : 2 } }
    }
}
