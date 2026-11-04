import Foundation

/// ブラインドキーの 1 回の押下または解放。時刻は単調時計の秒で保持する。
struct BlindKeyEvent: Codable, Equatable, Sendable {
    let hid: Int
    let down: Bool
    let t: Double
    let char: String?

    init(hid: Int, down: Bool, t: Double, char: String?) {
        self.hid = hid
        self.down = down
        self.t = t
        self.char = char
    }

    private enum CodingKeys: String, CodingKey {
        case hid, down, t, char
    }

    /// `char` が無い場合も protocol の例どおり null で明示する。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hid, forKey: .hid)
        try container.encode(down, forKey: .down)
        try container.encode(t, forKey: .t)
        if let char {
            try container.encode(char, forKey: .char)
        } else {
            try container.encodeNil(forKey: .char)
        }
    }
}
