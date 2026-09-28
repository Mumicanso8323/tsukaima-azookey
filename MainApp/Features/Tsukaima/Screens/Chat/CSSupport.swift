import SwiftUI

// 使い魔(チャット)・設定の両画面で共有する小物。通信は TsukaimaAPI(基盤)だけを使い、
// 返ってきた JSON はここで自前の JSONDecoder(snake_case → camelCase)に通す。
// 基盤側のデコーダ設定に依存しないようにするため。

@MainActor
enum CSNet {
    /// 署名もステップアップも要らない GET(クエリはここで渡す)
    static func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        let any = try await TsukaimaAPI.shared.getJSON(path, query: query)
        return try decode(any, as: type)
    }

    /// 署名(/api/main/* 系)・ステップアップ(Face ID)つきの要求。GET もこちらで送る
    static func send<T: Decodable>(_ method: String, _ path: String, json: [String: Any]? = nil,
                                   signed: Bool = false, stepup: Bool = false, as type: T.Type = T.self) async throws -> T {
        let any = try await TsukaimaAPI.shared.sendJSON(method, path, json: json, signed: signed, stepup: stepup)
        return try decode(any, as: type)
    }

    /// 応答の中身を使わない要求
    static func fire(_ method: String, _ path: String, json: [String: Any]? = nil,
                     signed: Bool = false, stepup: Bool = false) async throws {
        _ = try await TsukaimaAPI.shared.sendJSON(method, path, json: json, signed: signed, stepup: stepup)
    }

    static func decode<T: Decodable>(_ any: Any, as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: data)
    }

    /// パスの 1 区切り分をエスケープ(サイト名・端末 ID など)
    nonisolated static func seg(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 画面に出す失敗の一言。hub の detail(日本語の理由)があればそれを使う。
    /// 送った中身(パスワード・カード番号など)は決してここに含めない。
    nonisolated static func message(_ error: any Error, fallback: String = "失敗しました") -> String {
        guard let e = error as? TsukaimaAPIError else {
            return error is CancellationError ? "中断しました" : fallback
        }
        switch e {
        case .stepupCancelled:
            return "Face ID の確認ができませんでした"
        case .notPaired, .transport, .decoding:
            return e.errorDescription ?? fallback
        case .http(let status, let detail):
            if status == 429 { return "少し間を空けて送ってください" }
            if detail == "stepup_required" || (status == 401 && detail.isEmpty) { return "Face ID の確認ができませんでした" }
            if detail == "signature_required" { return "この端末の署名を確認できませんでした(端末の登録をやり直してください)" }
            if detail == "forbidden" { return "この経路からは使えません (403)" }
            return detail.isEmpty ? "\(fallback) (\(status))" : detail
        }
    }
}

/// 日付の表示(曜日つき "9/28(月)")・時刻
enum CSDate {
    private static let wd = Array("日月火水木金土")

    /// ISO 文字列の先頭 10 文字(yyyy-MM-dd)から "9/28(月)"
    static func md(_ iso: String?) -> String {
        guard let iso, iso.count >= 10 else { return "" }
        let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return "" }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        guard let d = Calendar(identifier: .gregorian).date(from: c) else { return "\(parts[1])/\(parts[2])" }
        let w = Calendar(identifier: .gregorian).component(.weekday, from: d) - 1
        return "\(parts[1])/\(parts[2])(\(wd[w]))"
    }

    /// ISO 文字列の時刻部分 "HH:mm"
    static func hm(_ iso: String?) -> String {
        guard let iso, iso.count >= 16 else { return "" }
        let s = iso.index(iso.startIndex, offsetBy: 11), e = iso.index(iso.startIndex, offsetBy: 16)
        return String(iso[s..<e])
    }

    static func parse(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }
}

// ---------- 文字の大きさ(設定で変更。端末ごとに保存) ----------
/// Web 版の「表示サイズ」にあたる。iOS の文字サイズ設定に上乗せして、この 2 画面の文字を大きく・小さくする。
enum CSTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, xLarge, xxLarge, huge

    static let storageKey = "tsukaima.textSize"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "小"
        case .standard: return "標準"
        case .large: return "大"
        case .xLarge: return "特大"
        case .xxLarge: return "特大+"
        case .huge: return "最大"
        }
    }

    var dynamicType: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .standard: return .large
        case .large: return .xLarge
        case .xLarge: return .xxLarge
        case .xxLarge: return .xxxLarge
        case .huge: return .accessibility2
        }
    }
}

struct CSTextSizeModifier: ViewModifier {
    @AppStorage(CSTextSize.storageKey) private var raw = CSTextSize.standard.rawValue
    func body(content: Content) -> some View {
        content.dynamicTypeSize((CSTextSize(rawValue: raw) ?? .standard).dynamicType)
    }
}

extension View {
    /// 設定の「文字の大きさ」をこの画面に当てる
    func tsukaimaTextSize() -> some View { modifier(CSTextSizeModifier()) }
}

/// 折り返して並べるチップ用の簡単なレイアウト
struct CSFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
