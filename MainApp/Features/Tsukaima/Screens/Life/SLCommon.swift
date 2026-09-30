import SwiftUI

// 勉強・生活タブ(画面 B)の共通部品。Web 版(portal-bot/web/app.js)の小道具(md・hm・yen・daysTo など)を
// そのまま移している。サーバの応答は形がまちまち(数値/文字列/0・1 の真偽/入れ子)なので、Web 版と同じ
// 「動的に読む」やり方で SLJSON に一度デコードしてから各画面で拾う。
// 他の画面(Today/Chat/Settings)と型名が衝突しないよう、この 2 フォルダの型はすべて SL で始める。

// MARK: - JSON(Web 版の素の JS オブジェクト相当)

enum SLJSON: Decodable, Sendable, Hashable {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case arr([SLJSON])
    case obj([String: SLJSON])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .num(d); return }
        if let s = try? c.decode(String.self) { self = .str(s); return }
        if let a = try? c.decode([SLJSON].self) { self = .arr(a); return }
        if let o = try? c.decode([String: SLJSON].self) { self = .obj(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON")
    }

    subscript(key: String) -> SLJSON {
        if case .obj(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> SLJSON {
        if case .arr(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    /// JS の真偽(null・false・0・"" は偽。配列・オブジェクトは空でも真)
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .num(let d): return d != 0 && !d.isNaN
        case .str(let s): return !s.isEmpty
        case .arr, .obj: return true
        }
    }

    /// 文字列として(数値は整数なら小数点なし)。null は nil
    var string: String? {
        switch self {
        case .str(let s): return s
        case .num(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// 表示用の文字列(null は空)
    var text: String { string ?? "" }

    var double: Double? {
        switch self {
        case .num(let d): return d
        case .str(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var int: Int? { double.map { Int($0.rounded()) } }

    var array: [SLJSON] { if case .arr(let a) = self { return a }; return [] }

    var object: [String: SLJSON] { if case .obj(let o) = self { return o }; return [:] }
}

// MARK: - 書式(Web 版と同じ表記)

enum SLFmt {
    static let weekdays = Array("日月火水木金土")

    /// "2026-09-28..." の先頭 10 文字から日付を作る(端末のローカル時刻 = JST 前提)
    static func day(_ iso: String) -> Date? {
        guard iso.count >= 10 else { return nil }
        let p = iso.prefix(10).split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// 曜日つきの日付 "9/28(月)"
    static func md(_ iso: String?) -> String {
        guard let iso, let date = day(iso) else { return "" }
        return md(date)
    }

    static func md(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .weekday], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)(\(weekdays[(c.weekday ?? 1) - 1]))"
    }

    /// "HH:MM"(ISO 文字列の 11〜16 文字目)
    static func hm(_ iso: String?) -> String {
        guard let iso, iso.count >= 16 else { return "" }
        let s = iso.index(iso.startIndex, offsetBy: 11), e = iso.index(iso.startIndex, offsetBy: 16)
        return String(iso[s..<e])
    }

    /// 今日から何日後か(過去は負)
    static func daysTo(_ iso: String) -> Int {
        guard let d = day(iso) else { return 0 }
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.dateComponents([.day], from: today, to: d).day ?? 0
    }

    /// 端末のローカル日付 "yyyy-MM-dd"(toISOString だと UTC にずれるので使わない)
    static func isoDay(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func grouped(_ n: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n.rounded())) ?? String(Int(n))
    }

    /// "¥1,234"
    static func yen(_ n: Double?) -> String { "¥" + grouped(n ?? 0) }

    static func yen(_ j: SLJSON) -> String { yen(j.double) }
}

// MARK: - エラー表示

enum SLError {
    /// 失敗をそのまま画面に出せる日本語にする(Web 版の alert 文言に合わせる)
    static func message(_ error: any Error, fallback: String = "失敗しました") -> String {
        if let e = error as? TsukaimaAPIError {
            switch e {
            case .stepupCancelled: return "Face ID の確認ができませんでした"
            case .notPaired: return "この端末がまだ登録されていません(設定で登録してください)"
            case .http(let status, let body):
                if status == 429 { return "少し間を空けて送ってください" }
                if let d = detail(body), !d.isEmpty { return d }
                return "\(fallback) (\(status))"
            case .transport: return "hub に接続できません"
            case .decoding: return "\(fallback)(応答を読めませんでした)"
            @unknown default: return fallback
            }
        }
        return fallback
    }

    /// FastAPI の {"detail": "..."} から文を取り出す(detail が文字列でないときは nil)
    static func detail(_ body: String) -> String? {
        switch body {
        case "stepup_required": return "Face ID の確認ができませんでした"
        case "signature_required": return "端末の署名が通りませんでした(設定で登録し直してください)"
        case "forbidden": return "この端末からは使えません"
        default: break
        }
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.hasPrefix("{") || t.hasPrefix("<") ? nil : String(t.prefix(200))
        }
        if let d = obj["detail"] as? String { return d }
        if let d = obj["detail"] as? [String: Any], (d["error"] as? String) == "stepup_required" {
            return "Face ID の確認ができませんでした"
        }
        return nil
    }

    static func status(_ error: any Error) -> Int? {
        if let e = error as? TsukaimaAPIError, case .http(let status, _) = e { return status }
        return nil
    }
}

// MARK: - API の薄い包み(契約: TsukaimaAPI.shared の get / send / upload だけを使う)

@MainActor
enum SLAPI {
    static func get(_ path: String, query: [String: String] = [:]) async throws -> SLJSON {
        try await TsukaimaAPI.shared.get(path, query: query)
    }

    /// サーバが require_stepup の GET(出費・分割・注文・カード)。契約の get には stepup が無いので send で叩く
    static func getStepup(_ path: String) async throws -> SLJSON {
        try await TsukaimaAPI.shared.send("GET", path, json: nil, signed: false, stepup: true)
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: SLBody] = [:], signed: Bool = false, stepup: Bool = false) async throws -> SLJSON {
        try await TsukaimaAPI.shared.send("POST", path, json: SLBody.encode(body), signed: signed, stepup: stepup)
    }

    @discardableResult
    static func delete(_ path: String, stepup: Bool = false) async throws -> SLJSON {
        try await TsukaimaAPI.shared.send("DELETE", path, json: nil, signed: false, stepup: stepup)
    }

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s
    }
}

/// 送る JSON 本文の値(Sendable に保つため Any を直接持ち回らない)
enum SLBody: Sendable {
    case s(String)
    case b(Bool)
    case d(Double)
    case strings([String])
    case null

    var any: Any {
        switch self {
        case .s(let v): return v
        case .b(let v): return v
        case .d(let v): return v
        case .strings(let v): return v
        case .null: return NSNull()
        }
    }

    static func encode(_ body: [String: SLBody]) -> [String: Any] {
        body.mapValues { $0.any }
    }
}

// MARK: - 見た目(Web 版の card・h2・s・badge)

struct SLCard<Content: View>: View {
    var accent = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent ? Color.orange : .clear, lineWidth: 2))
    }
}

struct SLHeader: View {
    let title: String
    var sub: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

/// 補足の小さい文字(Web 版の class="s")
struct SLSub: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct SLEmpty: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
    }
}

struct SLBadge: View {
    let text: String
    var color: Color = .orange
    var body: some View {
        Text(text).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.22)))
            .foregroundStyle(color)
    }
}

/// 詳細画面へのリンク行(Web 版の linkCard)
struct SLLinkRow: View {
    let icon: String
    let title: String
    var sub: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(icon).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
        .contentShape(Rectangle())
    }
}

/// 読み込み中・失敗の表示(Web 版の loading / 「読み込めませんでした」)
struct SLLoadState: View {
    let error: String?
    let retry: @MainActor () -> Void

    var body: some View {
        if let error {
            VStack(spacing: 10) {
                Text("読み込めませんでした (\(error))").foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("再読み込み", action: retry).buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
        }
    }
}

/// 締切までの日数の色(Web 版の due hot / warm)
struct SLDue: View {
    let text: String
    var hot = false
    var warm = false
    var body: some View {
        Text(text).font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((hot ? Color.red : warm ? Color.orange : Color.gray).opacity(0.25)))
            .foregroundStyle(hot ? Color.red : warm ? Color.orange : Color.secondary)
    }
}

/// 折りたたみ(Web 版の <details class="more">)
struct SLDisclosure<Content: View>: View {
    let title: String
    @State private var open = false
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }
}

/// 一時的なお知らせ(Web 版の toast / alert の代わり)
struct SLToast: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

extension View {
    func slToast(_ message: Binding<String?>) -> some View { modifier(SLToast(message: message)) }
}

// MARK: - 画像(食事の写真など。認証つきの GET なので AsyncImage は使えない)

/// 認証ヘッダつきで画像を取る。TsukaimaAPI の契約は JSON 専用なので、基盤の TsukaimaEndpoint
/// (接続先と合鍵の付け方)だけを借りて URLSession で読む。
@MainActor
final class SLImageCache {
    static let shared = SLImageCache()
    private var cache: [String: UIImage] = [:]

    func image(_ path: String) async -> UIImage? {
        if let img = cache[path] { return img }
        let req = TsukaimaEndpoint.request(TsukaimaEndpoint.url(path))
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        cache[path] = img
        return img
    }

    func data(_ path: String) async -> (Data, String?)? {
        let req = TsukaimaEndpoint.request(TsukaimaEndpoint.url(path))
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return (data, http.suggestedFilename)
    }
}

struct SLRemoteImage: View {
    let path: String
    var size: CGFloat = 52
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: path) { image = await SLImageCache.shared.image(path) }
    }
}

// MARK: - 「使い魔に聞く」(Web 版はチャットの入力欄に参照だけ入れて開く。ここでは同じ文をその場で送る)

struct SLAskSheet: View {
    let ref: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                SLSub("本文は渡さず、どの画面の物かの参照だけを付けてメインのセッションに送ります(使い魔が自分で調べます)。")
                TsukaimaTextEditor(text: $text)
                    .frame(minHeight: 140)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                Spacer()
            }
            .padding(16)
            .navigationTitle("使い魔に聞く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "送信中…" : "送る") { Task { await send() } }
                        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if text.isEmpty { text = "(使い魔の画面: \(ref)) " } }
            .slToast($message)
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await SLAPI.post("/api/main/send", ["text": .s(text.trimmingCharacters(in: .whitespacesAndNewlines))], signed: true)
            dismiss()
        } catch {
            message = SLError.message(error, fallback: "送れませんでした")
        }
    }
}

// MARK: - Web 版にしかないページ(3D モデル・部屋の素材など)を開く

enum SLWebPage {
    /// Web 版のページ。認証が端末の Cookie 前提なので、Tailscale 接続中に Safari で開く
    static func url(_ path: String) -> URL {
        URL(string: "https://\(TsukaimaEndpoint.tailscaleHost)\(path)")!
    }
}
