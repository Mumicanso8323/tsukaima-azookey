#!/usr/bin/env bash
set -euo pipefail

swiftc="$HOME/.local/share/swiftly/bin/swiftc"
if [[ ! -x "$swiftc" ]]; then
  echo "selftest: swiftc not found: $swiftc" >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
tempdir="$(mktemp -d)"
trap 'rm -rf "$tempdir"' EXIT

cat > "$tempdir/main.swift" <<'SWIFT'
import Foundation

var passed = 0
var failed = 0
@MainActor func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { passed += 1 }
    else { failed += 1; print("FAIL: \(name)") }
}
func code(_ source: String) -> MDBlock? { ClaudeMarkdown.parse(source).first }

let headings = ClaudeMarkdown.parse("# one #\n## two ###")
check(headings == [.heading(level: 1, text: "one"), .heading(level: 2, text: "two")], "ATX headings remove closing hashes")
check(code("first\nsecond") == .paragraph("first\nsecond"), "paragraph soft break")
let nested2 = ClaudeMarkdown.parse("- parent\n  - child")
check(nested2.count == 1, "two-space list parses")
if case let .list(_, _, items) = nested2.first { check(items.first?.blocks.contains(.list(ordered: false, start: 1, items: [MDListItem(checked: nil, blocks: [.paragraph("child")])])) == true, "two-space nested list") } else { check(false, "two-space nested list shape") }
let nested4 = ClaudeMarkdown.parse("- parent\n    - child")
if case let .list(_, _, items) = nested4.first { check(items.first?.blocks.contains(.list(ordered: false, start: 1, items: [MDListItem(checked: nil, blocks: [.paragraph("child")])])) == true, "four-space nested list") } else { check(false, "four-space nested list shape") }
if case let .list(ordered, start, _) = code("3) third") { check(ordered && start == 3, "ordered list start and paren") } else { check(false, "ordered list") }
if case let .list(_, _, items) = code("- [ ] open\n- [x] done\n- plain") { check(items.map(\.checked) == [false, true, nil], "task list") } else { check(false, "task list shape") }
if case let .code(language, body) = code("```swift\n# not heading\n```") { check(language == "swift" && body == "# not heading", "backtick fence") } else { check(false, "backtick fence shape") }
if case let .code(language, body) = code("~~~python\nprint(1)\n~~~") { check(language == "python" && body == "print(1)", "tilde fence") } else { check(false, "tilde fence shape") }
if case let .code(_, body) = code("```\nunclosed") { check(body == "unclosed", "unclosed fence") } else { check(false, "unclosed fence shape") }
if case let .code(_, body) = code("```\na | b\n# c\n```") { check(body.contains("|") && body.contains("#"), "fence ignores table and heading") } else { check(false, "fence literal content") }
let table = ClaudeMarkdown.parse("a | b | c\n:--- | :---: | ---:\n1 | 2")
if case let .table(header, alignments, rows) = table.first { check(header == ["a", "b", "c"], "table headers"); check(alignments == [.left, .center, .right], "table alignment"); check(rows == [["1", "2", ""]], "table pad short row") } else { check(false, "table shape"); check(false, "table alignment shape"); check(false, "table pad shape") }
let wideTable = ClaudeMarkdown.parse("a | b\n--- | ---\n1 | 2 | 3")
if case let .table(_, _, rows) = wideTable.first { check(rows == [["1", "2"]], "table truncates wide row") } else { check(false, "wide table shape") }
let escaped = ClaudeMarkdown.parse("a | b\n--- | ---\nx\\|y | z")
if case let .table(_, _, rows) = escaped.first { check(rows == [["x|y", "z"]], "escaped table pipe") } else { check(false, "escaped table shape") }
let quote = ClaudeMarkdown.parse("> quote\n> - item")
if case let .quote(blocks) = quote.first { check(blocks.count == 2 && blocks[1] == .list(ordered: false, start: 1, items: [MDListItem(checked: nil, blocks: [.paragraph("item")])]), "quote contains list") } else { check(false, "quote shape") }
check(code("---") == .rule && code("***") == .rule && code("___") == .rule, "horizontal rules")
check(code("![Alt text](https://example.test/a.png)") == .image(alt: "Alt text", source: "https://example.test/a.png"), "full-line image")
check(ClaudeMarkdown.parse("# h\r\n\r\ntext") == [.heading(level: 1, text: "h"), .paragraph("text")], "CRLF")
check(ClaudeMarkdown.parse("").isEmpty, "empty source")
check(ClaudeMarkdown.parse("\n\n \n\t\n").isEmpty, "blank source")
let swift = "let value = \"text\" // note\nprint(42)"
let swiftTokens = ClaudeCodeHighlighter.tokens(swift, language: "swift")
check(swiftTokens.contains { $0.kind == .keyword && String(swift[$0.range]) == "let" }, "Swift keyword")
check(swiftTokens.contains { $0.kind == .string && String(swift[$0.range]) == "\"text\"" }, "Swift string")
check(swiftTokens.contains { $0.kind == .comment && String(swift[$0.range]) == "// note" }, "Swift comment")
check(swiftTokens.contains { $0.kind == .number && String(swift[$0.range]) == "42" }, "number token")
check(zip(swiftTokens, swiftTokens.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound }, "tokens ordered and non-overlapping")
let python = ClaudeCodeHighlighter.tokens("def run():\n    # hello\n    return 2", language: "python")
check(python.contains { $0.kind == .keyword }, "Python keyword")
check(python.contains { $0.kind == .comment }, "Python comment")
let diff = ClaudeCodeHighlighter.tokens("+ added\n- removed", language: "diff")
check(diff.count == 2 && diff[0].kind == .string && diff[1].kind == .keyword, "diff lines")

if failed == 0 { print("selftest: \(passed) passed, 0 failed") }
else { print("selftest: \(passed) passed, \(failed) failed"); exit(1) }
SWIFT

"$swiftc" -swift-version 6 \
  "$root/MainApp/Features/Claude/ClaudeMarkdown.swift" \
  "$root/MainApp/Features/Claude/ClaudeCodeHighlighter.swift" \
  "$tempdir/main.swift" -o "$tempdir/selftest"
"$tempdir/selftest"
