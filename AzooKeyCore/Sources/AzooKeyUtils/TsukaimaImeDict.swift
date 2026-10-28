import Foundation

/// hub が育てるユーザ辞書(GET /api/ime/dict)。
/// キーボード拡張は Tailscale は元よりネットワークそのものに出ない方針なので、取得は本体アプリの
/// TsukaimaAPI.shared(api.yusukedoi.com + 端末の合鍵)が起動・前面化のたびに担い、結果を App Group に
/// アトミックに書く。キーボードはそのファイルを mtime の変化で読み直すだけ(HubUserDictionary)。
/// `{"updated_at": ISO8601, "words": [{"word","reading"(ひらがな),"hint"?}], "block"?: [String]}`
public enum TsukaimaImeDict {
    /// hub 側のパス。TsukaimaAPI.shared.get(apiPath) でそのまま叩ける。
    public static let apiPath = "/api/ime/dict"
    private static let fileName = "hub-dict.json"
    /// 本体アプリ側の取得間隔の目安(起動・前面化のたびに hub を叩きすぎない)
    public static let minFetchInterval: TimeInterval = 10 * 60

    public struct Payload: Codable, Equatable, Sendable {
        public var updated_at: String?
        public var words: [Word]
        public var block: [String]?

        public init(updated_at: String? = nil, words: [Word], block: [String]? = nil) {
            self.updated_at = updated_at
            self.words = words
            self.block = block
        }
    }

    public struct Word: Codable, Equatable, Sendable {
        public var word: String
        public var reading: String
        public var hint: String?

        public init(word: String, reading: String, hint: String? = nil) {
            self.word = word
            self.reading = reading
            self.hint = hint
        }
    }

    private static func directory(base: URL) -> URL {
        let dir = base.appendingPathComponent("tsukaima", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// App Group 内でのキャッシュ場所(本体アプリ・キーボードの両方から同じものを指す)
    public static func fileURL(base: URL) -> URL { directory(base: base).appendingPathComponent(fileName) }

    /// 本体アプリ側: 取得した JSON をアトミックに書く。失敗しても黙って諦める(次の起動・前面化でまた試す)。
    public static func write(_ data: Data, base: URL) {
        try? data.write(to: fileURL(base: base), options: .atomic)
    }
}
