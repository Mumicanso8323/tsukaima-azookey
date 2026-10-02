import SwiftUI

/// Claude タブの中から開くシート(アプリ内ブラウザ・ファイル閲覧・画像の拡大・テキストの選択・ファイル一覧)。
enum ClaudeSheet: Identifiable, Equatable {
    case browser(URL)
    /// hub 上のファイル(GET /api/claude/file)。HTML・画像・PDF・md・csv・コードなど
    case file(path: String)
    /// 画像の全画面表示。hub 上のパスか http(s) の URL
    case image(source: String)
    /// 本文を選んでコピーするためのシート(公式アプリの「テキストを選択」)
    case selectText(String)
    /// hub のファイル一覧(許可したフォルダだけ)。startDir が nil ならルートの一覧
    case files(startDir: String?)

    var id: String {
        switch self {
        case .browser(let u): return "browser:\(u.absoluteString)"
        case .file(let p): return "file:\(p)"
        case .image(let s): return "image:\(s)"
        case .selectText(let t): return "text:\(t.hashValue)"
        case .files(let d): return "files:\(d ?? "")"
        }
    }
}

/// リンクやカードを押したときの行き先を決めて、シートを出す。
/// 本文のリンクは `.environment(\.openURL, router.openURLAction)` でここに集まる。
@MainActor
final class ClaudeViewerRouter: ObservableObject {
    @Published var sheet: ClaudeSheet?

    /// アプリ内で開くファイルのリンク(ClaudeInline が絶対パスから作る)。
    ///   tsukaima-file://open?path=<パーセントエンコードした絶対パス>
    ///   tsukaima-file:///abs/path(HTML の中の相対リンクが解決された形)
    static let fileScheme = "tsukaima-file"

    static func fileURL(path: String) -> URL? {
        var c = URLComponents()
        c.scheme = fileScheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        return c.url
    }

    static func filePath(from url: URL) -> String? {
        guard url.scheme?.lowercased() == fileScheme else { return nil }
        if url.host == "open" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
        }
        let p = url.path
        return p.isEmpty ? nil : p
    }

    var openURLAction: OpenURLAction {
        OpenURLAction { [weak self] url in
            self?.open(url) ?? .systemAction
        }
    }

    @discardableResult
    func open(_ url: URL) -> OpenURLAction.Result {
        if let path = Self.filePath(from: url) {
            openFile(path)
            return .handled
        }
        switch url.scheme?.lowercased() {
        case "http", "https":
            sheet = .browser(url)
            return .handled
        default:
            // tel:・mailto: など。iOS に任せる
            return .systemAction
        }
    }

    func openFile(_ path: String) {
        if ClaudeFileKind(path: path) == .image {
            sheet = .image(source: path)
        } else {
            sheet = .file(path: path)
        }
    }

    func openImage(_ source: String) { sheet = .image(source: source) }
    func selectText(_ text: String) { sheet = .selectText(text) }
    func browseFiles(startDir: String?) { sheet = .files(startDir: startDir) }
}
