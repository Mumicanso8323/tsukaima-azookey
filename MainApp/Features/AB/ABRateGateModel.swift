import SwiftUI
import UIKit

/// 1 枚を 1--10 で採点する全画面の状態。ゲート本体が表示順と dismiss を管理する。
@MainActor
final class ABRateGateModel: ObservableObject {
    @Published private(set) var item: ABRateAPI.Item?
    @Published private(set) var image: UIImage?
    @Published private(set) var position: Int?
    @Published private(set) var total: Int?
    @Published private(set) var scale: ABRateAPI.Scale?
    @Published private(set) var busy = false
    @Published private(set) var showRetryHint = false
    @Published var note = ""

    /// 親の一つだけの fullScreenCover を閉じる/次の A/B に替えるための通知。
    var onFinished: (() -> Void)?

    private var scoredItemID: String?
    private var shownAt = Date()
    private var cache: [String: UIImage] = [:]

    var progressText: String {
        guard let position else { return "" }
        if let total { return "\(position)/\(total)" }
        return "\(position)"
    }

    /// 親が foreground の GET 結果を表示前に渡す。画像が読めない時はゲート自体を出さない。
    func prepare(_ status: ABRateAPI.Status) async throws {
        try await apply(status)
    }

    func score(_ value: Int) {
        guard !busy, let current = item, value >= 1, value <= 10 else { return }
        busy = true
        showRetryHint = false
        let capturedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        note = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        Task {
            do {
                if scoredItemID != current.id {
                    let ms = max(0, Int(Date().timeIntervalSince(shownAt) * 1000))
                    let response = try await apiRate(current.id, score: value,
                                                     note: capturedNote.isEmpty ? nil : capturedNote, ms: ms)
                    scoredItemID = current.id
                    if response.done {
                        finish()
                    } else if response.nextProvided, let next = response.next, next.done || next.item != nil {
                        try await advance(next)
                    } else {
                        // `next` が無い/ null/壊れている応答は、POST を重ねず GET で次だけ取り直す。
                        try await advance(apiNext())
                    }
                } else {
                    // POST は届いていたが次画像の取得だけ失敗した時の再試行。
                    try await advance(apiNext())
                }
            } catch {
                showRetryHint = true
            }
            busy = false
        }
    }

    // MARK: 内部

    private func advance(_ status: ABRateAPI.Status) async throws {
        guard !status.done, status.item != nil else {
            finish()
            return
        }
        // next を受け取った直後に先読みしてから差し替えるので、次の採点画面はキャッシュから出る。
        if let ref = status.item?.image { _ = try await imageFor(ref) }
        try await apply(status)
    }

    private func apply(_ status: ABRateAPI.Status) async throws {
        guard !status.done, let next = status.item else {
            finish()
            return
        }
        image = try await imageFor(next.image)
        item = next
        position = status.position
        total = status.total ?? total
        scale = status.scale ?? scale
        scoredItemID = nil
        shownAt = Date()
    }

    private func finish() {
        item = nil
        image = nil
        scoredItemID = nil
        onFinished?()
    }

    private func imageFor(_ ref: String) async throws -> UIImage {
        if let hit = cache[ref] { return hit }
        let result: UIImage
        if ABConfig.isRateMock, let mock = ABMockServer.rateImage(ref) {
            result = mock
        } else {
            let data = try await ABRateAPI.fetchImageData(ref)
            guard let decoded = UIImage(data: data) else { throw ABRateAPI.APIError.malformed }
            result = decoded
        }
        cache[ref] = result
        return result
    }

    private func apiNext() async throws -> ABRateAPI.Status {
        if ABConfig.isRateMock { return await ABMockServer.shared.rateNext() }
        // A/B だけの UI テストでは実サーバーを一切触らない。
        if ABConfig.isPairMock { return ABRateAPI.Status(done: true, item: nil, position: nil, total: nil, scale: nil) }
        return try await ABRateAPI.fetchNext()
    }

    private func apiRate(_ id: String, score: Int, note: String?, ms: Int) async throws -> ABRateAPI.VoteResponse {
        if ABConfig.isRateMock { return await ABMockServer.shared.rate(itemID: id, score: score, note: note) }
        return try await ABRateAPI.rate(itemID: id, score: score, note: note, ms: ms)
    }
}
