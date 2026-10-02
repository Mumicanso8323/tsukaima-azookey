import QuickLook
import SwiftUI
import UIKit
import WebKit

struct ClaudeFileViewer: View {
    let path: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ClaudeFileContentView(path: path)
                .navigationTitle((path as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
            // 「完了」は ClaudeFileContentView のツールバーにある(一覧から push したときも同じ)
        }
    }
}

struct ClaudeFileContentView: View {
    let path: String
    @State private var fileURL: URL?
    @State private var contents: Data?
    @State private var error: ClaudeFileError?
    @State private var retry = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("ファイルを開けません", systemImage: "exclamationmark.triangle", description: Text(error.errorDescription ?? "不明なエラー")) {
                    Button("もう一度") { retry += 1 }
                }
            } else if let fileURL, let contents {
                viewer(url: fileURL, data: contents)
            } else {
                ProgressView("読み込み中…")
            }
        }
        .accessibilityIdentifier("claude.fileViewer")
        .task(id: "\(path)-\(retry)") { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let fileURL { ShareLink(item: fileURL) { Image(systemName: "square.and.arrow.up") } }
                Menu {
                    Button("パスをコピー") { UIPasteboard.general.string = path }
                } label: { Image(systemName: "ellipsis.circle") }
                Button("完了") { dismiss() }
                    .accessibilityIdentifier("claude.sheet.done")
            }
        }
    }

    @ViewBuilder private func viewer(url: URL, data: Data) -> some View {
        switch ClaudeFileKind(path: path) {
        case .html:
            ClaudeHTMLView(path: path)
                .accessibilityIdentifier("claude.fileViewer.html")
        case .markdown:
            ClaudeMarkdownFileView(markdown: String(decoding: data, as: UTF8.self))
        case .csv:
            ClaudeCSVView(text: String(decoding: data, as: UTF8.self), isTSV: (path as NSString).pathExtension.lowercased() == "tsv")
        case .code, .text:
            ClaudeCodeFileView(code: Self.clippedText(data), language: Self.language(for: path), wasClipped: data.count > 1_000_000)
        case .image:
            ClaudeInlineImageView(data: data)
        case .pdf, .office, .other:
            ClaudeQuickLookView(url: url)
        }
    }

    @MainActor private func load() async {
        error = nil
        fileURL = nil
        contents = nil
        do {
            let url = try await ClaudeFileStore.shared.fetch(path: path)
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            fileURL = url
            contents = data
        } catch let fileError as ClaudeFileError {
            self.error = fileError
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }

    private static func clippedText(_ data: Data) -> String {
        String(decoding: data.prefix(1_000_000), as: UTF8.self)
    }

    private static func language(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "py": return "python"
        case "js", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "rs": return "rust"
        case "cpp", "hpp": return "cpp"
        case "m", "mm": return "objc"
        default: return ext.isEmpty ? nil : ext
        }
    }
}

struct ClaudeFileBrowser: View {
    let startDir: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ClaudeDirectoryList(dir: startDir)
                .navigationTitle("ファイル")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") { dismiss() }
                            .accessibilityIdentifier("claude.sheet.done")
                    }
                }
        }
    }
}

private struct ClaudeDirectoryList: View {
    let dir: String?
    @State private var listing: ClaudeDirListing?
    @State private var error: ClaudeFileError?
    @State private var retry = 0

    var body: some View {
        Group {
            if let listing {
                List {
                    if let current = listing.dir {
                        Text(current).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ForEach(listing.entries) { entry in
                        if entry.isDir {
                            NavigationLink { ClaudeDirectoryList(dir: entry.path).navigationTitle(entry.name) } label: { row(entry) }
                        } else {
                            NavigationLink { ClaudeFileContentView(path: entry.path).navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline) } label: { row(entry) }
                        }
                    }
                    if listing.truncated {
                        Label("一覧は一部だけ表示しています", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("claude.files")
            } else if let error {
                ContentUnavailableView("一覧を開けません", systemImage: "exclamationmark.triangle", description: Text(error.errorDescription ?? "不明なエラー")) {
                    Button("もう一度") { retry += 1 }
                }
            } else {
                ProgressView("読み込み中…")
                    .accessibilityIdentifier("claude.files")
            }
        }
        .task(id: "\(dir ?? "root")-\(retry)") { await load() }
    }

    private func row(_ entry: ClaudeDirEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDir ? "folder" : ClaudeFileKind(path: entry.path).icon)
                .foregroundStyle(entry.isDir ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                if let detail = detail(entry) { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityIdentifier("claude.files.row.\(entry.name)")
    }

    private func detail(_ entry: ClaudeDirEntry) -> String? {
        var values: [String] = []
        if let size = entry.size { values.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let mtime = entry.mtime { values.append(mtime) }
        return values.isEmpty ? nil : values.joined(separator: " ・ ")
    }

    @MainActor private func load() async {
        listing = nil
        error = nil
        do { listing = try await ClaudeFileStore.shared.list(dir: dir) }
        catch let fileError as ClaudeFileError { self.error = fileError }
        catch { self.error = .network(error.localizedDescription) }
    }
}

private struct ClaudeMarkdownFileView: View {
    let markdown: String
    @State private var source = false

    var body: some View {
        Group {
            if source {
                ScrollView([.horizontal, .vertical]) {
                    Text(markdown).font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding()
                }
            } else {
                ScrollView { ClaudeMarkdownView(markdown: markdown).padding() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(source ? "表示" : "原文") { source.toggle() } }
        }
    }
}

private struct ClaudeCSVView: View {
    let text: String
    let isTSV: Bool
    @State private var rows: [[String]] = []
    @State private var omitted = 0

    var body: some View {
        ScrollView(.horizontal) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).font(index == 0 ? .body.bold() : .body).textSelection(.enabled)
                                    .frame(minWidth: 120, alignment: .leading).padding(8)
                                    .background(index == 0 ? Color.secondary.opacity(0.16) : .clear)
                                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.2)))
                            }
                        }
                    }
                    if omitted > 0 { Text("…ほか \(omitted) 行").foregroundStyle(.secondary).padding(8) }
                }
            }
        }
        .task(id: text) {
            let source = text
            let separator: Character = isTSV ? "\t" : ","
            let parsed = await Task.detached(priority: .userInitiated) { Self.parse(source, separator: separator) }.value
            rows = Array(parsed.prefix(1_000))
            omitted = max(0, parsed.count - 1_000)
        }
    }

    nonisolated private static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [[]]
        var cell = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" { cell.append(character); index = next }
                else { quoted.toggle() }
            } else if character == separator, !quoted {
                rows[rows.count - 1].append(cell); cell = ""
            } else if (character == "\n" || character == "\r"), !quoted {
                if character == "\r", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "\n" { index = text.index(after: index) }
                rows[rows.count - 1].append(cell); cell = ""; rows.append([])
            } else { cell.append(character) }
            index = text.index(after: index)
        }
        if !rows.last!.isEmpty || !cell.isEmpty { rows[rows.count - 1].append(cell) } else { rows.removeLast() }
        return rows
    }
}

private struct ClaudeCodeFileView: View {
    let code: String
    let language: String?
    let wasClipped: Bool

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 10) {
                Text((1...max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)).map(String.init).joined(separator: "\n"))
                    .foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
                ClaudeHighlightedCode(code: code, language: language)
            }
            .font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding()
            if wasClipped { Text("先頭 1 MB だけを表示しています").foregroundStyle(.orange).padding(.bottom) }
        }
    }
}

private struct ClaudeHighlightedCode: View {
    let code: String
    let language: String?
    @State private var value = AttributedString()

    var body: some View {
        Text(value).fixedSize(horizontal: true, vertical: false)
            .task(id: code) {
                let source = code
                let lang = language
                value = await Task.detached(priority: .userInitiated) {
                    Self.highlight(source, language: lang)
                }.value
            }
    }

    nonisolated private static func highlight(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString(code)
        for token in ClaudeCodeHighlighter.tokens(code, language: language) {
            let lower = result.index(result.startIndex, offsetBy: code.distance(from: code.startIndex, to: token.range.lowerBound))
            let upper = result.index(result.startIndex, offsetBy: code.distance(from: code.startIndex, to: token.range.upperBound))
            result[lower..<upper].foregroundColor = color(token.kind)
        }
        return result
    }

    nonisolated private static func color(_ kind: CodeTokenKind) -> Color {
        switch kind {
        case .plain: return .primary
        case .keyword: return .purple
        case .string: return .green
        case .comment: return .secondary
        case .number: return .orange
        case .type: return .blue
        case .function: return .pink
        }
    }
}

private struct ClaudeInlineImageView: View {
    let data: Data
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { ZoomableImageView(image: image, backgroundColor: .systemBackground) }
            else { ProgressView() }
        }
        .task(id: data) {
            let source = data
            image = await Task.detached(priority: .userInitiated) {
                ClaudeImageViewer.downsample(data: source, maxPixel: 2_048)
            }.value
        }
    }
}

private struct ClaudeQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) { context.coordinator.url = url; uiViewController.reloadData() }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct ClaudeHTMLView: UIViewRepresentable {
    let path: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptEnabled = true
        configuration.setURLSchemeHandler(ClaudeFileSchemeHandler(), forURLScheme: ClaudeViewerRouter.fileScheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.accessibilityIdentifier = "claude.fileViewer.html"
        webView.load(URLRequest(url: Self.fileURL(path: path)))
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private static func fileURL(path: String) -> URL {
        var components = URLComponents()
        components.scheme = ClaudeViewerRouter.fileScheme
        components.path = path
        return components.url!
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}

@MainActor
private final class ClaudeFileSchemeHandler: NSObject, WKURLSchemeHandler {
    /// 止められた要求(止めた後に didReceive すると例外で落ちるので覚えておく)
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url, let path = ClaudeViewerRouter.filePath(from: requestURL) else {
            urlSchemeTask.didFailWithError(ClaudeFileError.notAFile); return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        Task { @MainActor in
            do {
                let url = try await ClaudeFileStore.shared.fetch(path: path)
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                guard !self.stopped.contains(key) else { return }
                let response = URLResponse(url: requestURL, mimeType: Self.mimeType(path: path), expectedContentLength: data.count, textEncodingName: "utf-8")
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard !self.stopped.contains(key) else { return }
                urlSchemeTask.didFailWithError(error)
            }
            self.stopped.remove(key)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask))
    }

    nonisolated private static func mimeType(path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}
