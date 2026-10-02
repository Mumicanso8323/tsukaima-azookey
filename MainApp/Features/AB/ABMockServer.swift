import UIKit

/// UI テスト用の偽サーバー(起動引数 `--ab-mock`)。3 組を手元で作り、投票はメモリに記録する。本番では動かない。
@MainActor
final class ABMockServer {
    static let shared = ABMockServer()

    static let total = 3
    private(set) var votes: [(pairID: String, choice: ABChoice)] = []

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
}
