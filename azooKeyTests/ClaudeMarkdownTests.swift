import Foundation
@testable import azooKey
import XCTest

final class ClaudeMarkdownTests: XCTestCase {
    func testHeadingsParagraphsAndLineEndings() {
        XCTAssertEqual(ClaudeMarkdown.parse("# title ##\r\n\r\nfirst\r\nsecond"), [
            .heading(level: 1, text: "title"),
            .paragraph("first\nsecond"),
        ])
        XCTAssertEqual(ClaudeMarkdown.parse(""), [])
        XCTAssertEqual(ClaudeMarkdown.parse("\n \n\t"), [])
    }

    func testListsTasksAndNestedIndentation() throws {
        let blocks = ClaudeMarkdown.parse("3) first\n    - [ ] child\n    - [x] done\n4) second")
        guard case let .list(ordered, start, items) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected a list")
        }
        XCTAssertTrue(ordered)
        XCTAssertEqual(start, 3)
        XCTAssertEqual(items.count, 2)
        guard case let .list(childOrdered, _, children) = try XCTUnwrap(items[0].blocks.last) else {
            return XCTFail("expected nested list")
        }
        XCTAssertFalse(childOrdered)
        XCTAssertEqual(children.map(\.checked), [false, true])

        let twoSpace = ClaudeMarkdown.parse("- outer\n  - inner")
        guard case let .list(_, _, twoItems) = try XCTUnwrap(twoSpace.first), case .list = try XCTUnwrap(twoItems.first?.blocks.last) else {
            return XCTFail("two-space nesting was not recognized")
        }
    }

    func testFencesTablesQuotesRulesAndImages() throws {
        let fenced = ClaudeMarkdown.parse("~~~swift\n# literal | text\n~~~\n---\n![alt](https://example.test/a.png)")
        XCTAssertEqual(fenced[0], .code(language: "swift", code: "# literal | text"))
        XCTAssertEqual(fenced[1], .rule)
        XCTAssertEqual(fenced[2], .image(alt: "alt", source: "https://example.test/a.png"))
        XCTAssertEqual(ClaudeMarkdown.parse("```\nmissing close").first, .code(language: nil, code: "missing close"))

        let table = ClaudeMarkdown.parse("one | two | three\n:--- | :---: | ---:\na\\|b | c | d | ignored")
        guard case let .table(header, alignments, rows) = try XCTUnwrap(table.first) else { return XCTFail("expected table") }
        XCTAssertEqual(header, ["one", "two", "three"])
        XCTAssertEqual(alignments, [.left, .center, .right])
        XCTAssertEqual(rows, [["a|b", "c", "d"]])

        let quote = ClaudeMarkdown.parse("> quoted\n> - listed")
        guard case let .quote(contents) = try XCTUnwrap(quote.first) else { return XCTFail("expected quote") }
        XCTAssertEqual(contents.first, .paragraph("quoted"))
        guard case .list = contents.last else { return XCTFail("quote should contain list") }
    }

    func testInlineLinks() {
        #if canImport(Darwin)
        let quoted = ClaudeInline.attributed("メモは `/data/ashwell/mock/notes.md` に置いた")
        XCTAssertEqual(quoted.runs.compactMap(\.link).first?.absoluteString, "tsukaima-file://open?path=%2Fdata%2Fashwell%2Fmock%2Fnotes.md",
                       "インラインコードの中のパスもリンクになる")
        let value = ClaudeInline.attributed("https://example.test /data/ashwell/project/readme.md ~/notes/todo.md")
        let links = value.runs.compactMap(\.link)
        XCTAssertTrue(links.contains(URL(string: "https://example.test")!))
        XCTAssertTrue(links.contains(URL(string: "tsukaima-file://open?path=%2Fdata%2Fashwell%2Fproject%2Freadme.md")!))
        XCTAssertTrue(links.contains(URL(string: "tsukaima-file://open?path=%2Fhome%2Fashwell%2Fnotes%2Ftodo.md")!))
        #endif
    }

    func testHighlighterRecognizesAndOrdersTokens() {
        let source = "let greeting = \"hello\" // explain\nprint(42)"
        let tokens = ClaudeCodeHighlighter.tokens(source, language: "swift")
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && String(source[$0.range]) == "let" })
        XCTAssertTrue(tokens.contains { $0.kind == .string && String(source[$0.range]) == "\"hello\"" })
        XCTAssertTrue(tokens.contains { $0.kind == .comment && String(source[$0.range]) == "// explain" })
        XCTAssertTrue(tokens.contains { $0.kind == .number && String(source[$0.range]) == "42" })
        XCTAssertTrue(zip(tokens, tokens.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound })
    }
}
