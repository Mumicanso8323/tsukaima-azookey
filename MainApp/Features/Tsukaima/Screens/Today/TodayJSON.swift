import Foundation

/// 今日タブで使うサーバー応答の汎用表現。
/// /api/today などは形が緩い(注文は Face ID 前だと中身が落ちる・items は文字列か辞書・id は数値か文字列)ので、
/// 型を固定せずこれで受けて、画面側で web 版(portal-bot/web/app.js)と同じ読み方をする。
/// Sendable なので TsukaimaAPI(別の isolation かもしれない)からそのまま受け取れる。
enum TodayJSON: Decodable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([TodayJSON])
    case object([String: TodayJSON])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([TodayJSON].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: TodayJSON].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON value")
        }
    }

    subscript(_ key: String) -> TodayJSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    /// キーがあるか(注文の中身が伏せられているかの判定に使う)
    func has(_ key: String) -> Bool {
        if case .object(let o) = self { return o[key] != nil }
        return false
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    /// 文字列として(数値は整数なら小数点なし)。null・配列・辞書は nil
    var str: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// 文字列(無ければ空)
    var s: String { str ?? "" }

    var num: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var int: Int? { num.map { Int($0) } }

    var arr: [TodayJSON] {
        if case .array(let a) = self { return a }
        return []
    }

    /// JavaScript の真偽(web 版の `if (x)` と同じ判定)
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }
}

/// 送信するボディ(Sendable)。TsukaimaAPI に渡す直前に Any(JSONSerialization 形)へ組み立てる。
enum TodayBody: Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case null

    var any: Any {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b
        case .int(let i): return i
        case .null: return NSNull()
        }
    }
}

/// 今日タブのサーバー呼び出し。TsukaimaAPI(基盤)の契約だけを使う。
@MainActor
enum TodayAPI {
    static func get(_ path: String, query: [String: String] = [:]) async throws -> TodayJSON {
        try await TsukaimaAPI.shared.get(path, query: query)
    }

    static func send(_ method: String, _ path: String, body: [String: TodayBody]? = nil,
                     signed: Bool = false, stepup: Bool = false) async throws -> TodayJSON {
        let json = makeJSON(body)
        return try await TsukaimaAPI.shared.send(method, path, json: json, signed: signed, stepup: stepup)
    }

    private static func makeJSON(_ body: [String: TodayBody]?) -> Any? {
        guard let body else { return nil }
        var d: [String: Any] = [:]
        for (k, v) in body { d[k] = v.any }
        return d
    }

    /// パスに埋め込む id(/ や @ を含む予定 id でも 1 セグメントになるように)
    nonisolated static func seg(_ id: String) -> String {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-._~")
        return id.addingPercentEncoding(withAllowedCharacters: ok) ?? id
    }

    nonisolated static func isCancelled(_ e: any Error) -> Bool {
        if case .stepupCancelled? = e as? TsukaimaAPIError { return true }
        return e is CancellationError
    }

    nonisolated static func status(_ e: any Error) -> Int? {
        if case .http(let code, _)? = e as? TsukaimaAPIError { return code }
        return nil
    }

    /// 画面に出す短い説明。サーバーの detail があればそれを出す
    nonisolated static func message(_ e: any Error) -> String {
        guard let err = e as? TsukaimaAPIError else { return e.localizedDescription }
        if case .http(let code, let detail) = err { return detail.isEmpty ? "HTTP \(code)" : detail }
        return err.localizedDescription
    }
}

/// 日付・時刻の表示。web 版の md()/hm()/daysTo()/dueLabel() と同じ結果になるようにする。
/// サーバーの時刻は Python の isoformat(例 "2026-09-28T09:00:00+09:00"・日付だけ "2026-09-28")。
enum TodayFmt {
    static let weekdays: [String] = ["日", "月", "火", "水", "木", "金", "土"]

    private static func part(_ s: String, _ from: Int, _ to: Int) -> Int? {
        let chars = Array(s)
        guard chars.count >= to else { return nil }
        return Int(String(chars[from..<to]))
    }

    /// "2026-09-28..." の日付部分を端末の 0 時として
    static func day(_ iso: String) -> Date? {
        guard let y = part(iso, 0, 4), let m = part(iso, 5, 7), let d = part(iso, 8, 10) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// 時刻つきの ISO 文字列を Date に(オフセットが無ければ端末の時刻として)
    static func date(_ iso: String) -> Date? {
        guard let y = part(iso, 0, 4), let mo = part(iso, 5, 7), let d = part(iso, 8, 10) else { return nil }
        var comps = DateComponents(year: y, month: mo, day: d)
        comps.hour = part(iso, 11, 13) ?? 0
        comps.minute = part(iso, 14, 16) ?? 0
        comps.second = part(iso, 17, 19) ?? 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        // オフセット(+09:00 / -05:00 / Z)を探す
        let chars = Array(iso)
        if chars.count > 19 {
            var i = 19
            if chars[i] == "." { i += 1; while i < chars.count, chars[i].isNumber { i += 1 } }
            if i < chars.count {
                if chars[i] == "Z" {
                    cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                } else if chars[i] == "+" || chars[i] == "-", i + 3 <= chars.count,
                          let hh = Int(String(chars[(i + 1)..<(i + 3)])) {
                    var mm = 0
                    if i + 6 <= chars.count, let v = Int(String(chars[(i + 4)..<(i + 6)])) { mm = v }
                    let sign = chars[i] == "-" ? -1 : 1
                    cal.timeZone = TimeZone(secondsFromGMT: sign * (hh * 3600 + mm * 60)) ?? .current
                }
            }
        }
        return cal.date(from: comps)
    }

    /// "9/28(月)"
    static func md(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty, let m = part(iso, 5, 7), let d = part(iso, 8, 10), let day = day(iso) else { return "" }
        let w = Calendar.current.component(.weekday, from: day) - 1
        return "\(m)/\(d)(\(weekdays[w]))"
    }

    /// "09:00"(ISO の 11〜16 文字目。web 版と同じく文字列のまま切り出す)
    static func hm(_ iso: String?) -> String {
        guard let iso else { return "" }
        let chars = Array(iso)
        guard chars.count >= 16 else { return "" }
        return String(chars[11..<16])
    }

    /// 今日の日付(端末の日付)を "9/28(月)" で
    static func mdToday(_ now: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .weekday], from: now)
        return "\(c.month ?? 0)/\(c.day ?? 0)(\(weekdays[(c.weekday ?? 1) - 1]))"
    }

    /// 今日から何日後か(日付単位)
    static func daysTo(_ iso: String) -> Int {
        guard let d = day(iso) else { return 0 }
        let t = Calendar.current.startOfDay(for: Date())
        return Int((d.timeIntervalSince(t) / 86400).rounded())
    }

    static func dueLabel(_ iso: String) -> String {
        let n = daysTo(iso)
        return n <= 0 ? "今日" : n == 1 ? "明日" : "あと\(n)日"
    }

    /// "2026-09-28" 形式(端末の日付)
    static func isoDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
