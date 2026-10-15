import Foundation

/// キーボード拡張のライフサイクル・パンくず。キーボードにまともなネットワークが無い前提で、
/// App Group 内のファイルに溜めるだけ溜めて、本体アプリが起動・前面化のたびに吸い出して hub へ送る。
/// 「キーボードが動かなくなった」を後から追うための最小限のログで、個人の入力内容は書かない。
public enum TsukaimaKeyboardBreadcrumb {
    private static let fileName = "kb-breadcrumb.log"
    private static let maxLines = 200
    /// この行数を超えたら切り詰める(毎回 200 行ちょうどに詰め直すコストを避けるための遊び)
    private static let trimThreshold = maxLines * 2
    /// キーボード拡張の CFBundleVersion を本体アプリから読めるようにしておく共有キー
    public static let buildKey = "kb.lastSeenBuild"

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private static var fileURL: URL {
        SharedStore.sharedContainerURL.appendingPathComponent(fileName)
    }

    /// キーボード拡張の CFBundleVersion を共有 UserDefaults に書いておく(本体アプリが起動時に読む)。
    @MainActor
    public static func recordBuild() {
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "?"
        SharedStore.userDefaults.set(build, forKey: buildKey)
    }

    /// パンくずを 1 行追加する(キーボード拡張側から呼ぶ)。失敗しても黙って諦める。
    public static func add(_ s: String) {
        let line = fmt.string(from: .now) + " " + s + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        trimIfNeeded()
    }

    private static func trimIfNeeded() {
        let url = fileURL
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > trimThreshold else { return }
        let trimmed = lines.suffix(maxLines).joined(separator: "\n") + "\n"
        try? trimmed.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// 溜まっている行を読む(消さない。送信に成功した本体アプリ側が `clear()` を呼ぶ)。
    public static func peek() -> [String] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(maxLines).map { $0 }
    }

    /// アップロードに成功したときだけ呼ぶ。
    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
