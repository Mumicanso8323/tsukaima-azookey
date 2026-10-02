import SwiftUI
import UIKit

/// アプリが前面に来たとき /api/ab/next を見て、未回答の組があれば全画面で A/B を出す(オーナーは押すだけ)。
/// 通信エラーは黙って何も出さない(次に前面へ来たときにまた試す)。
@MainActor
final class ABGateModel: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var pair: ABAPI.Pair?
    @Published private(set) var imageA: UIImage?
    @Published private(set) var imageB: UIImage?
    @Published private(set) var position: Int?
    @Published private(set) var total: Int?
    @Published private(set) var busy = false
    @Published private(set) var showRetryHint = false

    private var checking = false
    /// 投票は届いたが次の組の取得に失敗した組(やり直しでは投票し直さず、次だけ取る)
    private var votedPairID: String?
    private var shownAt = Date()
    private var cache: [String: UIImage] = [:]

    var progressText: String {
        guard let position else { return "" }
        if let total { return "\(position)/\(total)" }
        return "\(position)"
    }

    /// 前面に来たとき・起動直後に呼ぶ。表示中は何もしない。
    func checkOnForeground() {
        guard !isPresented, !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            guard let status = try? await apiNext() else { return }
            guard !status.done, status.pair != nil else { return }
            do {
                try await apply(status)
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
        if ABConfig.isMock, let m = ABMockServer.image(ref) {
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
        if ABConfig.isMock { return await ABMockServer.shared.next() }
        return try await ABAPI.fetchNext()
    }

    private func apiVote(_ id: String, _ choice: ABChoice, ms: Int) async throws -> ABAPI.Status {
        if ABConfig.isMock { return await ABMockServer.shared.vote(pairID: id, choice: choice) }
        return try await ABAPI.vote(pairID: id, choice: choice, ms: ms)
    }
}
