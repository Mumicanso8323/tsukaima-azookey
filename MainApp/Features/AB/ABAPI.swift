import Foundation

/// A/B テスト(ノアの絵柄)の設定。起動引数 `--ab-mock` のときは偽サーバー(ABMockServer)で動く(UI テスト専用)。
enum ABConfig {
    static let isMock = ProcessInfo.processInfo.arguments.contains("--ab-mock")
}

enum ABChoice: String, Sendable {
    case a = "A"
    case b = "B"
    case none = "none"
}

/// `/api/ab/*` の形をここだけに閉じ込める。サーバー側の形が確定したらこのファイルだけ直す。
/// 解析は寛容(キーの別名・数値の id・`next`/`pair` どちらでも)。
enum ABAPI {
    struct Pair: Equatable, Sendable {
        var id: String
        /// 画像の URL(絶対)かパス("/" 始まり。TsukaimaEndpoint の基準 URL で解決する)。モックは "mock:..."。
        var a: String
        var b: String
    }

    struct Status: Equatable, Sendable {
        var done: Bool
        var pair: Pair?
        /// 画面に出す「いま何問目か」(1 始まり)
        var position: Int?
        var total: Int?
    }

    enum APIError: Error {
        case malformed
        case http(Int)
    }

    // MARK: 解析(純ロジック・単体テスト対象)

    /// `GET /api/ab/next` の本文。done が無く pair も無ければ「もう無い」として done 扱い。
    nonisolated static func parseNext(_ data: Data) throws -> Status {
        try parse(data, doneIfMissing: nil)
    }

    /// `POST /api/ab/vote` の本文。done が無ければ false(next が無ければ呼び側が /next を取り直す)。
    nonisolated static func parseVote(_ data: Data) throws -> Status {
        try parse(data, doneIfMissing: false)
    }

    nonisolated private static func parse(_ data: Data, doneIfMissing: Bool?) throws -> Status {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed
        }
        // vote の応答の next は /api/ab/next と同じ形({done,pair,index,total})。pair だけが入っていても読む。
        if let nextObj = obj["next"] as? [String: Any], nextObj["pair"] != nil || nextObj["done"] != nil {
            var inner = try parse(try JSONSerialization.data(withJSONObject: nextObj), doneIfMissing: nil)
            if let d = obj["done"] as? Bool, d { inner = Status(done: true, pair: nil, position: nil, total: inner.total) }
            if inner.total == nil { inner.total = int(obj["total"]) }
            if inner.position == nil { inner.position = int(obj["index"]) }
            return inner
        }
        let pairObj = (obj["pair"] as? [String: Any]) ?? (obj["next"] as? [String: Any])
        let pair = pairObj.flatMap(parsePair)
        let done = (obj["done"] as? Bool) ?? doneIfMissing ?? (pair == nil)
        let progress = obj["progress"] as? [String: Any]
        let total = int(obj["total"]) ?? int(progress?["total"])
        var position = int(obj["index"])
        if position == nil, let answered = int(progress?["answered"]) { position = answered + 1 }
        return Status(done: done, pair: done ? nil : pair, position: position, total: total)
    }

    nonisolated private static func parsePair(_ o: [String: Any]) -> Pair? {
        guard let id = string(o["id"]) ?? string(o["pair_id"]),
              let a = url(o["a"]) ?? url(o["a_url"]) ?? url(o["image_a"]),
              let b = url(o["b"]) ?? url(o["b_url"]) ?? url(o["image_b"]) else { return nil }
        return Pair(id: id, a: a, b: b)
    }

    nonisolated private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    nonisolated private static func url(_ v: Any?) -> String? {
        if let s = string(v) { return s }
        if let d = v as? [String: Any] { return string(d["url"]) }
        return nil
    }

    nonisolated private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    // MARK: 通信

    nonisolated static func resolve(_ ref: String) -> URL? {
        ref.hasPrefix("/") ? TsukaimaEndpoint.url(ref) : URL(string: ref)
    }

    nonisolated static func fetchNext() async throws -> Status {
        let data = try await send(TsukaimaEndpoint.request(TsukaimaEndpoint.url("/api/ab/next")))
        return try parseNext(data)
    }

    private struct VoteBody: Encodable, Sendable {
        let pair_id: String
        let choice: String
        /// 組が表示されてから押すまでのミリ秒
        let ms: Int?
    }

    nonisolated static func vote(pairID: String, choice: ABChoice, ms: Int?) async throws -> Status {
        var req = TsukaimaEndpoint.request(TsukaimaEndpoint.url("/api/ab/vote"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(VoteBody(pair_id: pairID, choice: choice.rawValue, ms: ms))
        let data = try await send(req)
        return try parseVote(data)
    }

    /// 画像のバイト列(認証ヘッダは TsukaimaEndpoint.request が必要なホストにだけ付ける)
    nonisolated static func fetchImageData(_ ref: String) async throws -> Data {
        guard let url = resolve(ref) else { throw APIError.malformed }
        return try await send(TsukaimaEndpoint.request(url))
    }

    nonisolated private static func send(_ req: URLRequest) async throws -> Data {
        var req = req
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
        return data
    }
}
