import SwiftUI
import UIKit

struct ClaudeMarkdownView: View {
    let blocks: [MDBlock]
    private let imageView: (String, String) -> AnyView

    init(blocks: [MDBlock], image: @escaping (String, String) -> AnyView = ClaudeMarkdownView.defaultImage) {
        self.blocks = blocks
        self.imageView = image
    }

    init(markdown: String, image: @escaping (String, String) -> AnyView = ClaudeMarkdownView.defaultImage) {
        self.init(blocks: ClaudeMarkdown.parse(markdown), image: image)
    }

    var body: some View {
        ClaudeMarkdownBlockStack(blocks: blocks, imageView: imageView)
    }

    static func defaultImage(_ alt: String, _ source: String) -> AnyView {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return AnyView(Text("画像: \(alt)").foregroundStyle(.secondary))
        }
        return AnyView(
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: Text("画像: \(alt)").foregroundStyle(.secondary)
                default: ProgressView().accessibilityLabel(alt)
                }
            }
        )
    }
}

private struct ClaudeMarkdownBlockStack: View {
    let blocks: [MDBlock]
    let imageView: (String, String) -> AnyView
    var listDepth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(ClaudeInline.attributed(text))
                .font(headingFont(level))
                .textSelection(.enabled)
                .padding(.top, 5)
        case .paragraph(let text):
            Text(ClaudeInline.attributed(text))
                .font(.body)
                .textSelection(.enabled)
        case .list(let ordered, let start, let items):
            ClaudeMarkdownList(items: items, ordered: ordered, start: start, depth: listDepth, imageView: imageView)
        case .code(let language, let code):
            ClaudeMarkdownCodeBlock(language: language, code: code)
        case .table(let header, let alignments, let rows):
            ClaudeMarkdownTable(header: header, alignments: alignments, rows: rows)
        case .quote(let quoted):
            HStack(alignment: .top, spacing: 9) {
                Rectangle().fill(Color.secondary.opacity(0.55)).frame(width: 3)
                ClaudeMarkdownBlockStack(blocks: quoted, imageView: imageView, listDepth: listDepth)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case .rule:
            Divider().padding(.vertical, 4)
        case .image(let alt, let source):
            imageView(alt, source)
                .accessibilityLabel(alt)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }
}

private struct ClaudeMarkdownList: View {
    let items: [MDListItem]
    let ordered: Bool
    let start: Int
    let depth: Int
    let imageView: (String, String) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .top, spacing: 7) {
                    marker(item: item, offset: offset)
                        .frame(minWidth: 20, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    ClaudeMarkdownBlockStack(blocks: item.blocks, imageView: imageView, listDepth: depth + 1)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    @ViewBuilder private func marker(item: MDListItem, offset: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square" : "square")
                .accessibilityLabel(checked ? "完了" : "未完了")
        } else if ordered {
            Text("\(start + offset).")
        } else {
            Text(depth % 3 == 0 ? "•" : (depth % 3 == 1 ? "◦" : "▪"))
        }
    }
}

private struct ClaudeMarkdownCodeBlock: View {
    let language: String?
    let code: String
    private let highlighted: AttributedString
    @State private var copied = false

    init(language: String?, code: String) {
        self.language = language
        self.code = code
        var value = AttributedString(code)
        for token in ClaudeCodeHighlighter.tokens(code, language: language) {
            let lowerOffset = code.distance(from: code.startIndex, to: token.range.lowerBound)
            let upperOffset = code.distance(from: code.startIndex, to: token.range.upperBound)
            let lower = value.index(value.startIndex, offsetBy: lowerOffset)
            let upper = value.index(value.startIndex, offsetBy: upperOffset)
            value[lower..<upper].foregroundColor = Self.color(for: token.kind)
        }
        self.highlighted = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(language?.isEmpty == false ? language! : "コード")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Text(copied ? "コピーしました" : "コピー")
                        .font(.caption.weight(.medium))
                }
                .accessibilityIdentifier("claude.md.copyCode")
            }
            ScrollView(.horizontal) {
                Text(highlighted)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func color(for kind: CodeTokenKind) -> Color {
        Color(UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch kind {
            case .keyword: return dark ? UIColor(red: 0.78, green: 0.58, blue: 1, alpha: 1) : UIColor(red: 0.42, green: 0.20, blue: 0.67, alpha: 1)
            case .string: return dark ? UIColor(red: 1, green: 0.64, blue: 0.51, alpha: 1) : UIColor(red: 0.62, green: 0.23, blue: 0.12, alpha: 1)
            case .comment: return dark ? UIColor.lightGray : UIColor.darkGray
            case .number: return dark ? UIColor(red: 0.45, green: 0.75, blue: 1, alpha: 1) : UIColor(red: 0.08, green: 0.37, blue: 0.72, alpha: 1)
            case .type: return dark ? UIColor(red: 0.36, green: 0.86, blue: 0.80, alpha: 1) : UIColor(red: 0.00, green: 0.44, blue: 0.40, alpha: 1)
            case .function: return dark ? UIColor(red: 0.45, green: 0.82, blue: 1, alpha: 1) : UIColor(red: 0.00, green: 0.43, blue: 0.65, alpha: 1)
            case .plain: return dark ? .white : .black
            }
        })
    }
}

private struct ClaudeMarkdownTable: View {
    let header: [String]
    let alignments: [MDAlign]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], column: column, heading: true)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(rows[row][column], column: column, heading: false)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
        }
    }

    private func cell(_ text: String, column: Int, heading: Bool) -> some View {
        Text(ClaudeInline.attributed(text))
            .font(heading ? .body.bold() : .body)
            .textSelection(.enabled)
            .frame(minWidth: 86, alignment: alignment(at: column))
            .padding(8)
            .background(heading ? Color(.secondarySystemBackground) : Color.clear)
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.25)))
    }

    private func alignment(at column: Int) -> Alignment {
        switch column < alignments.count ? alignments[column] : .none {
        case .center: return .center
        case .right: return .trailing
        case .none, .left: return .leading
        }
    }
}
