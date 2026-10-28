import UIKit

/// UI テスト用の偽サーバー(`--ab-mock` / `--rate-mock`)。投票・採点はメモリに記録する。本番では動かない。
@MainActor
final class ABMockServer {
    static let shared = ABMockServer()

    static let total = 3
    private(set) var votes: [(pairID: String, choice: ABChoice)] = []
    private(set) var scores: [(itemID: String, score: Int)] = []

    private func pair(_ n: Int) -> ABAPI.Pair {
        ABAPI.Pair(id: "mock\(n)", a: "mock:\(n):A", b: "mock:\(n):B")
    }

    private func status() -> ABAPI.Status {
        let answered = votes.count
        if answered >= Self.total { return ABAPI.Status(done: true, pair: nil, position: nil, total: Self.total) }
        return ABAPI.Status(done: false, pair: pair(answered + 1), position: answered + 1, total: Self.total)
    }

    func next() async -> ABAPI.Status {
        try? await Task.sleep(for: .milliseconds(300))
        return status()
    }

    /// 通信の遅れを模す(連打しても 1 回しか進まないことを試せるように)
    func vote(pairID: String, choice: ABChoice) async -> ABAPI.Status {
        try? await Task.sleep(for: .milliseconds(600))
        votes.append((pairID, choice))
        return status()
    }

    private func rateItem(_ n: Int) -> ABRateAPI.Item {
        ABRateAPI.Item(id: "rate-mock\(n)", image: "mock-rate:\(n)")
    }

    private func rateStatus() -> ABRateAPI.Status {
        let answered = scores.count
        let scale = ABRateAPI.Scale(min: 1, max: 10, low: "全然ダメ", high: "最高")
        if answered >= Self.total {
            return ABRateAPI.Status(done: true, item: nil, position: nil, total: Self.total, scale: scale)
        }
        return ABRateAPI.Status(done: false, item: rateItem(answered + 1), position: answered + 1, total: Self.total, scale: scale)
    }

    func rateNext() async -> ABRateAPI.Status {
        try? await Task.sleep(for: .milliseconds(300))
        return rateStatus()
    }

    /// A/B と同じ 0.6 秒の遅れを入れ、連打が一問しか進めないことを UI テストで確認する。
    func rate(itemID: String, score: Int, note _: String?) async -> ABRateAPI.VoteResponse {
        try? await Task.sleep(for: .milliseconds(600))
        scores.append((itemID, score))
        let next = rateStatus()
        return ABRateAPI.VoteResponse(done: next.done, next: next.done ? nil : next,
                                      nextProvided: true, roundComplete: next.done, notified: false)
    }

    /// "mock:<n>:<A|B>" の縦長の単色画像。A と B で色が違い、文字も入れる。
    static func image(_ ref: String) -> UIImage? {
        let parts = ref.split(separator: ":")
        guard parts.count == 3, parts[0] == "mock" else { return nil }
        let n = Int(parts[1]) ?? 1
        let isA = parts[2] == "A"
        let hue = CGFloat((n * 3 + (isA ? 0 : 1)) % 12) / 12
        let color = UIColor(hue: hue, saturation: 0.55, brightness: isA ? 0.85 : 0.6, alpha: 1)
        let size = CGSize(width: 300, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = String(parts[2]) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 200),
                .foregroundColor: UIColor.white,
            ]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2), withAttributes: attrs)
        }
    }

    /// "mock-rate:<n>" の縦長の単色画像。採点画面で現在の item が視覚的にも区別できる。
    static func rateImage(_ ref: String) -> UIImage? {
        let parts = ref.split(separator: ":")
        guard parts.count == 2, parts[0] == "mock-rate", let n = Int(parts[1]) else { return nil }
        let size = CGSize(width: 300, height: 600)
        let color = UIColor(hue: CGFloat((n * 4) % 12) / 12, saturation: 0.58, brightness: 0.78, alpha: 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "\(n)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 200),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attrs)
        }
    }
}
