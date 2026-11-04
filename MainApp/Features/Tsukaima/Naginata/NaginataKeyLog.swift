import Foundation

/// 練習中の打鍵ログ(キーと時刻だけ。本文は書かない)。Documents/naginata-practice-log.jsonl に 1 行 1 打鍵。
/// 行: {"s":セッションID,"k":"w"|"space"|...,"d":"down"|"up","t":起動からの秒}
enum NaginataKeyLog {
    static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("naginata-practice-log.jsonl")
    }

    private static let queue = DispatchQueue(label: "naginata.keylog")

    static func line(session: String, key: Character, down: Bool, t: TimeInterval) -> String {
        let object: [String: Any] = [
            "s": session,
            "k": key == " " ? "space" : String(key),
            "d": down ? "down" : "up",
            "t": t,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// 1 行を追記する(失敗しても入力には影響させない)
    static func append(_ line: String, to url: URL = NaginataKeyLog.fileURL) {
        guard !line.isEmpty else { return }
        queue.async {
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
