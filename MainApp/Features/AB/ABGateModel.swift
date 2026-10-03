import SwiftUI
import UIKit

/// アプリが前面に来たとき rating と A/B の両方を見て、一枚だけの全画面ゲートを出す。
/// 通信エラーは黙って何も出さない(次に前面へ来たときにまた試す)。
@MainActor
final class ABGateModel: ObservableObject {
    enum Mode {
        case rate
        case pair
    }

    @Published var isPresented = false
    @Published private(set) var mode: Mode = .pair
    @Published private(set) var pair: ABAPI.Pair?
    @Published private(set) var imageA: UIImage?
    @Published private(set) var imageB: UIImage?
    @Published private(set) var position: Int?
    @Published private(set) var total: Int?
    @Published private(set) var busy = false
    @Published private(set) var showRetryHint = false

    let rateGate = ABRateGateModel()

    private var checking = false
    /// rating を先に終えた直後に出す、同じ foreground GET で得た A/B の状態。
    private var queuedPair: ABAPI.Status?
    /// 投票は届いたが次の組の取得に失敗した組(やり直しでは投票し直さず、次だけ取る)
    private var votedPairID: String?
    private var shownAt = Date()
    private var cache: [String: UIImage] = [:]

    init() {
        rateGate.onFinished = { [weak self] in
            self?.ratingFinished()
        }
    }

    var progressText: String {
        guard let position else { return "" }
        if let total { return "\(position)/\(total)" }
        return "\(position)"
    }

    /// 前面に来たとき・起動直後に呼ぶ。rating を常に先にし、表示中・完了後には再照会しない。
    func checkOnForeground() {
        guard !isPresented, !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            // 片方が失敗してももう片方はゲートできる。どちらも失敗/完了なら何も表示しない。
            let rateStatus = try? await rateNext()
            let pairStatus = try? await apiNext()
            if let rateStatus, !rateStatus.done, rateStatus.item != nil {
                queuedPair = pairStatus
                do {
                    try await rateGate.prepare(rateStatus)
                    mode = .rate
                    isPresented = true
                } catch {
                    // 画像が取れなければ何も出さない
                }
                return
            }
            guard let pairStatus, !pairStatus.done, pairStatus.pair != nil else { return }
            do {
                try await apply(pairStatus)
                mode = .pair
                isPresented = true
            } catch {
                // 画像が取れなければ何も出さない
            }
        }
    }

    func vote(_ choice: ABChoice) {
        guard !busy, let current = pair else { return }
        busy = true
        showRetryHint = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                if votedPairID != current.id {
                    let ms = max(0, Int(Date().timeIntervalSince(shownAt) * 1000))
                    var status = try await apiVote(current.id, choice, ms: ms)
                    votedPairID = current.id
                    if status.done || status.pair != nil {
                        try await apply(status)
                        busy = false
                        return
                    }
                    status = try await apiNext()
                    try await apply(status)
                } else {
                    try await apply(try await apiNext())
                }
            } catch {
                showRetryHint = true
            }
            busy = false
        }
    }

    // MARK: 内部

    private func apply(_ status: ABAPI.Status) async throws {
        guard !status.done, let next = status.pair else {
            isPresented = false
            pair = nil
            imageA = nil
            imageB = nil
            votedPairID = nil
            return
        }
        let ia = try await image(next.a)
        let ib = try await image(next.b)
        pair = next
        imageA = ia
        imageB = ib
        position = status.position
        total = status.total ?? total
        votedPairID = nil
        shownAt = Date()
    }

    private func image(_ ref: String) async throws -> UIImage {
        if let hit = cache[ref] { return hit }
        let img: UIImage
        if ABConfig.isPairMock, let m = ABMockServer.image(ref) {
            img = m
        } else {
            let data = try await ABAPI.fetchImageData(ref)
            guard let decoded = UIImage(data: data) else { throw ABAPI.APIError.malformed }
            img = decoded
        }
        cache[ref] = img
        return img
    }

    private func apiNext() async throws -> ABAPI.Status {
        if ABConfig.isPairMock { return await ABMockServer.shared.next() }
        // rating だけの UI テストでは実サーバーを一切触らない。
        if ABConfig.isRateMock { return ABAPI.Status(done: true, pair: nil, position: nil, total: nil) }
        return try await ABAPI.fetchNext()
    }

    private func apiVote(_ id: String, _ choice: ABChoice, ms: Int) async throws -> ABAPI.Status {
        if ABConfig.isPairMock { return await ABMockServer.shared.vote(pairID: id, choice: choice) }
        return try await ABAPI.vote(pairID: id, choice: choice, ms: ms)
    }

    private func rateNext() async throws -> ABRateAPI.Status {
        if ABConfig.isRateMock { return await ABMockServer.shared.rateNext() }
        // A/B だけの UI テストでは実サーバーを一切触らない。
        if ABConfig.isPairMock { return ABRateAPI.Status(done: true, item: nil, position: nil, total: nil, scale: nil) }
        return try await ABRateAPI.fetchNext()
    }

    private func ratingFinished() {
        guard let queuedPair, !queuedPair.done, queuedPair.pair != nil else {
            isPresented = false
            return
        }
        Task {
            do {
                try await apply(queuedPair)
                mode = .pair
            } catch {
                // rating は完了済みなので、A/B の画像が取れなければアプリへ戻す。
                isPresented = false
            }
        }
    }
}
