import Foundation

/// 接続待ちのキーを、古い順に保持する小さなリングバッファ。
struct BlindKeyQueue: Sendable {
    static let maximumEvents = 500
    static let maximumAge: TimeInterval = 60
    static let maximumBatchSize = 200

    private var storage: [BlindKeyEvent?] = Array(repeating: nil, count: maximumEvents)
    private var start = 0
    private(set) var count = 0

    mutating func append(_ event: BlindKeyEvent, now: TimeInterval) {
        discardExpired(now: now)
        guard event.t >= now - Self.maximumAge else { return }
        if count == Self.maximumEvents {
            removeFirst(1)
        }
        storage[(start + count) % Self.maximumEvents] = event
        count += 1
    }

    /// 期限切れを除いて、未送信分をすべて古い順に返す。
    mutating func drain(now: TimeInterval) -> [BlindKeyEvent] {
        discardExpired(now: now)
        let result = elements()
        removeFirst(result.count)
        return result
    }

    /// `drain` した結果を protocol の上限以下に区切る。
    mutating func batches(now: TimeInterval) -> [[BlindKeyEvent]] {
        let events = drain(now: now)
        return stride(from: 0, to: events.count, by: Self.maximumBatchSize).map {
            Array(events[$0..<min($0 + Self.maximumBatchSize, events.count)])
        }
    }

    /// 送信完了を待つ間もキューを失わないための、内部利用向け先頭バッチ。
    mutating func firstBatch(now: TimeInterval) -> [BlindKeyEvent] {
        discardExpired(now: now)
        return Array(elements().prefix(Self.maximumBatchSize))
    }

    mutating func removeFirst(_ number: Int) {
        guard number > 0 else { return }
        let amount = min(number, count)
        for _ in 0..<amount {
            storage[start] = nil
            start = (start + 1) % Self.maximumEvents
            count -= 1
        }
    }

    private mutating func discardExpired(now: TimeInterval) {
        let active = elements().filter { $0.t >= now - Self.maximumAge }
        guard active.count != count else { return }
        storage = Array(repeating: nil, count: Self.maximumEvents)
        start = 0
        count = active.count
        for (offset, event) in active.enumerated() {
            storage[offset] = event
        }
    }

    private func elements() -> [BlindKeyEvent] {
        (0..<count).compactMap { element(at: $0) }
    }

    private func element(at offset: Int) -> BlindKeyEvent? {
        guard offset >= 0, offset < count else { return nil }
        return storage[(start + offset) % Self.maximumEvents]
    }
}
