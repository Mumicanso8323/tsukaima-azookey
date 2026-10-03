import Foundation

/// 1--10 採点 API の形をここだけに閉じ込める。A/B API と同様、サーバー移行中の別名も読む。
enum ABRateAPI {
    struct Item: Codable, Equatable, Sendable {
        var id: String
        var image: String
    }

    struct Scale: Codable, Equatable, Sendable {
        var min: Int
        var max: Int
        var low: String
        var high: String
    }

    struct Status: Codable, Equatable, Sendable {
        var done: Bool
        var item: Item?
        /// 画面に出す「いま何問目か」(1 始まり)
        var position: Int?
        var total: Int?
        var scale: Scale?
    }

    /// POST の追加情報。`nextProvided` は `next` が無い時に GET を取り直すために必要。
    struct VoteResponse: Codable, Equatable, Sendable {
        var done: Bool
        var next: Status?
        var nextProvided: Bool
        var roundComplete: Bool
        var notified: Bool
    }

    enum APIError: Error, Sendable {
        case malformed
        case http(Int)
    }

    // MARK: 解析(純ロジック・単体テスト対象)

    nonisolated static func parseNext(_ data: Data) throws -> Status {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed
        }
        return parseStatus(object, doneIfMissing: nil)
    }

    nonisolated static func parseVote(_ data: Data) throws -> VoteResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed
        }
        let done = bool(object["done"]) ?? false
        let nextProvided = object.keys.contains("next")
        var nextStatus: Status?
        if let nextObject = object["next"] as? [String: Any] {
            var parsed = try parseStatus(nextObject, doneIfMissing: nil)
            if done {
                parsed.done = true
                parsed.item = nil
            }
            nextStatus = parsed
        }
        return VoteResponse(
            done: done,
            next: nextStatus,
            nextProvided: nextProvided,
            roundComplete: bool(object["round_complete"]) ?? bool(object["roundComplete"]) ?? false,
            notified: bool(object["notified"]) ?? false
        )
    }

    nonisolated private static func parseStatus(_ object: [String: Any], doneIfMissing: Bool?) throws -> Status {
        let itemObject = (object["item"] as? [String: Any]) ?? directItemObject(object)
        let item = itemObject.flatMap(parseItem)
        let done = bool(object["done"]) ?? doneIfMissing ?? (item == nil)
        let progress = object["progress"] as? [String: Any]
        let total = int(object["total"]) ?? int(progress?["total"])
        var position = int(object["index"])
        if position == nil, let answered = int(progress?["answered"]) { position = answered + 1 }
        return Status(done: done, item: done ? nil : item, position: position, total: total,
                      scale: (object["scale"] as? [String: Any]).flatMap(parseScale))
    }

    /// POST の `next` が item 本体だけで来る旧形も読む。
    nonisolated private static func directItemObject(_ object: [String: Any]) -> [String: Any]? {
        guard object["id"] != nil || object["item_id"] != nil else { return nil }
        return object
    }

    nonisolated private static func parseItem(_ object: [String: Any]) -> Item? {
        guard let id = string(object["id"]) ?? string(object["item_id"]),
              let image = url(object["image"]) ?? url(object["url"]) else { return nil }
        return Item(id: id, image: image)
    }

    nonisolated private static func parseScale(_ object: [String: Any]) -> Scale? {
        guard let min = int(object["min"]), let max = int(object["max"]),
              let low = string(object["low"]), let high = string(object["high"]) else { return nil }
        return Scale(min: min, max: max, low: low, high: high)
    }

    nonisolated private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    nonisolated private static func url(_ value: Any?) -> String? {
        if let value = string(value) { return value }
        if let object = value as? [String: Any] { return string(object["url"]) }
        return nil
    }

    nonisolated private static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    nonisolated private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return Bool(value) }
        return nil
    }

    // MARK: 通信

    nonisolated static func fetchNext() async throws -> Status {
        let data = try await send(TsukaimaEndpoint.request(TsukaimaEndpoint.url("/api/ab/rate/next")))
        return try parseNext(data)
    }

    private struct RateBody: Encodable, Sendable {
        let item_id: String
        let score: Int
        let note: String?
        let ms: Int?
    }

    nonisolated static func rate(itemID: String, score: Int, note: String?, ms: Int?) async throws -> VoteResponse {
        var request = TsukaimaEndpoint.request(TsukaimaEndpoint.url("/api/ab/rate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RateBody(item_id: itemID, score: score, note: note, ms: ms))
        let data = try await send(request)
        return try parseVote(data)
    }

    /// A/B と同じ認証付き request builder を通して webp を取る。AsyncImage は使わない。
    nonisolated static func fetchImageData(_ ref: String) async throws -> Data {
        try await ABAPI.fetchImageData(ref)
    }

    nonisolated private static func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
        return data
    }
}
