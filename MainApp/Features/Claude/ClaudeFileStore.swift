import CryptoKit
import Foundation
import UIKit

struct ClaudeDirEntry: Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int?
    let mtime: String?

    var id: String { path }
}

struct ClaudeDirListing: Equatable, Sendable {
    let dir: String?
    let parent: String?
    let entries: [ClaudeDirEntry]
    let truncated: Bool
}

enum ClaudeFileError: LocalizedError, Equatable {
    case forbidden, notFound, tooLarge, notAFile, network(String), status(Int)

    var errorDescription: String? {
        switch self {
        case .forbidden: return "許可されていない場所か、見せない種類のファイルです"
        case .notFound: return "ファイルが見つかりません"
        case .tooLarge: return "ファイルが大きすぎます（50 MB を超えています）"
        case .notAFile: return "これはファイルではありません"
        case .network(let message): return "通信に失敗しました: \(message)"
        case .status(let code): return "サーバーがエラーを返しました（\(code)）"
        }
    }
}

actor ClaudeFileStore {
    static let shared = ClaudeFileStore()

    private struct CacheEntry: Sendable {
        let url: URL
        let date: Date
    }

    private struct ListingResponse: Decodable, Sendable {
        let dir: String?
        let parent: String?
        let entries: [Entry]
        let truncated: Bool

        struct Entry: Decodable, Sendable {
            let name: String
            let path: String
            let isDir: Bool
            let size: Int?
            let mtime: String?

            enum CodingKeys: String, CodingKey {
                case name, path, size, mtime
                case isDir = "is_dir"
            }
        }
    }

    private var files: [String: CacheEntry] = [:]
    private var imageData: [String: Data] = [:]
    private var imageOrder: [String] = []
    private let cacheLifetime: TimeInterval = 60

    func fetch(path: String) async throws -> URL {
        if let cached = files[path], Date().timeIntervalSince(cached.date) < cacheLifetime,
           FileManager.default.fileExists(atPath: cached.url.path) {
            return cached.url
        }

        let data = try await download(path: path)
        let destination = cacheURL(path: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        files[path] = CacheEntry(url: destination, date: Date())
        return destination
    }

    func data(path: String) async throws -> Data {
        if let cached = imageData[path] { return cached }
        let value = try await download(path: path)
        imageData[path] = value
        imageOrder.append(path)
        if imageOrder.count > 50 {
            imageData.removeValue(forKey: imageOrder.removeFirst())
        }
        return value
    }

    func list(dir: String?) async throws -> ClaudeDirListing {
        if ClaudeConfig.isMock { return try mockListing(dir: dir) }
        var components = URLComponents(url: TsukaimaEndpoint.url("/api/claude/files"), resolvingAgainstBaseURL: false)!
        if let dir { components.queryItems = [URLQueryItem(name: "dir", value: dir)] }
        guard let url = components.url else { throw ClaudeFileError.network("URL を作れません") }
        var request = TsukaimaEndpoint.request(url)
        request.timeoutInterval = 60
        let (data, response) = try await requestData(request)
        try check(response)
        do {
            let listing = try JSONDecoder().decode(ListingResponse.self, from: data)
            return ClaudeDirListing(
                dir: listing.dir, parent: listing.parent,
                entries: listing.entries.map { ClaudeDirEntry(name: $0.name, path: $0.path, isDir: $0.isDir, size: $0.size, mtime: $0.mtime) },
                truncated: listing.truncated
            )
        } catch {
            throw ClaudeFileError.network("一覧の形式を読めません")
        }
    }

    private func download(path: String) async throws -> Data {
        if ClaudeConfig.isMock { return try mockData(path: path) }
        var components = URLComponents(url: TsukaimaEndpoint.url("/api/claude/file"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else { throw ClaudeFileError.network("URL を作れません") }
        var request = TsukaimaEndpoint.request(url)
        request.timeoutInterval = 60
        let (data, response) = try await requestData(request)
        try check(response)
        return data
    }

    private func requestData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: request) }
        catch { throw ClaudeFileError.network(error.localizedDescription) }
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClaudeFileError.network("不正な応答です") }
        switch http.statusCode {
        case 200...299: return
        case 400: throw ClaudeFileError.notAFile
        case 403: throw ClaudeFileError.forbidden
        case 404: throw ClaudeFileError.notFound
        case 413: throw ClaudeFileError.tooLarge
        default: throw ClaudeFileError.status(http.statusCode)
        }
    }

    private func cacheURL(path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = (path as NSString).lastPathComponent.isEmpty ? "file" : (path as NSString).lastPathComponent
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("claude-files", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(16)), isDirectory: true)
            .appendingPathComponent(name)
    }

    private func mockData(path: String) throws -> Data {
        if path.localizedCaseInsensitiveContains("forbidden") { throw ClaudeFileError.forbidden }
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown":
            return Data("# モックのメモ\n\n- 確認する項目\n- 共有する項目\n\n```swift\nprint(\"表示できています\")\n```\n".utf8)
        case "html", "htm":
            return Data("<h1>モックの成果物</h1><p id=\"mock\">表示できています</p>".utf8)
        case "csv", "tsv":
            let separator = path.hasSuffix(".tsv") ? "\t" : ","
            return Data(["名前", "状態", "担当"].joined(separator: separator).appending("\n案,確認中,Claude\n実装,完了,Tsukaima\nテスト,予定,人間\n").utf8)
        case "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "h", "cpp", "java", "rb", "php", "sh":
            return Data((1...20).map { "// mock line \($0)\nlet value\($0) = \($0)" }.joined(separator: "\n").utf8)
        case "png", "jpg", "jpeg":
            return mockImageData()
        case "pdf":
            return mockPDFData()
        default:
            return Data("モックのファイルです。\n表示できています。\nパス: \(path)\n".utf8)
        }
    }

    private func mockListing(dir: String?) throws -> ClaudeDirListing {
        if dir?.localizedCaseInsensitiveContains("forbidden") == true { throw ClaudeFileError.forbidden }
        switch dir {
        // UI テストはルートをそのまま開くため、最初の画面にも notes.md を並べる。
        case nil, "/mock":
            return ClaudeDirListing(dir: "/mock", parent: nil, entries: [
                ClaudeDirEntry(name: "docs", path: "/mock/docs", isDir: true, size: nil, mtime: nil),
                ClaudeDirEntry(name: "report.html", path: "/mock/report.html", isDir: false, size: 94, mtime: "2026-10-02T10:00:00Z"),
                ClaudeDirEntry(name: "notes.md", path: "/mock/notes.md", isDir: false, size: 156, mtime: "2026-10-02T10:01:00Z"),
                ClaudeDirEntry(name: "data.csv", path: "/mock/data.csv", isDir: false, size: 72, mtime: "2026-10-02T10:02:00Z"),
                ClaudeDirEntry(name: "main.swift", path: "/mock/main.swift", isDir: false, size: 486, mtime: "2026-10-02T10:03:00Z"),
                ClaudeDirEntry(name: "photo.png", path: "/mock/photo.png", isDir: false, size: 1_024, mtime: "2026-10-02T10:04:00Z")
            ], truncated: false)
        case "/mock/docs":
            return ClaudeDirListing(dir: "/mock/docs", parent: "/mock", entries: [ClaudeDirEntry(name: "plan.md", path: "/mock/docs/plan.md", isDir: false, size: 112, mtime: "2026-10-02T10:05:00Z")], truncated: false)
        default:
            return ClaudeDirListing(dir: dir, parent: nil, entries: [], truncated: false)
        }
    }

    private func mockImageData() -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 40, y: 40, width: 320, height: 220))
            let text = "Mock"
            text.draw(at: CGPoint(x: 150, y: 130), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.white])
        }
        return image.pngData() ?? Data()
    }

    private func mockPDFData() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { context in
            context.beginPage()
            "モックの PDF\n表示できています".draw(in: CGRect(x: 72, y: 72, width: 460, height: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
    }
}
