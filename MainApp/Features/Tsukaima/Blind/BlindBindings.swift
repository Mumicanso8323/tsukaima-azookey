import Foundation

/// 合図の動作。rawValue はサーバー(blind-keys-protocol.md の config)の action 名と同じ。
enum BlindAction: String, Codable, CaseIterable {
    case toggle
    case mode
    case voice
    case read

    var label: String {
        switch self {
        case .toggle: "入る・出る"
        case .mode: "かな・英数"
        case .voice: "声の入切"
        case .read: "溜めた返事を読む"
        }
    }
}

/// キーの押し方。rawValue はサーバーの style 名と同じ。
enum BlindStyle: String, Codable, CaseIterable {
    case double
    case hold
    case tap

    var label: String {
        switch self {
        case .double: "2回押し"
        case .hold: "長押し"
        case .tap: "1回押し"
        }
    }
}

struct BlindBinding: Codable, Equatable, Hashable {
    let action: BlindAction
    let hid: Int
    let style: BlindStyle
}

/// 本人が選んだ合図のキー(最大 16 件)。1 つのキーは 1 つの動作にだけ割り当てる。
struct BlindBindings: Codable, Equatable {
    static let maximumCount = 16
    static let hidRange = 0...0xFFFF

    private(set) var entries: [BlindBinding] = []

    init() {}

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    /// 壊れた・多すぎる保存値でも、規則(範囲・1 キー 1 動作・16 件)を満たす分だけ読む。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([BlindBinding].self, forKey: .entries)
        for binding in decoded {
            _ = set(binding)
        }
    }

    /// 同じキーの前の割り当てを消して入れる。範囲外の hid、または満杯で新しいキーを足せない時は false。
    @discardableResult
    mutating func set(_ b: BlindBinding) -> Bool {
        guard Self.hidRange.contains(b.hid) else { return false }
        let previous = entries
        entries.removeAll { $0.hid == b.hid }
        guard entries.count < Self.maximumCount else {
            entries = previous
            return false
        }
        entries.append(b)
        return true
    }

    mutating func remove(hid: Int) {
        entries.removeAll { $0.hid == hid }
    }

    func bindings(for hid: Int) -> [BlindBinding] {
        entries.filter { $0.hid == hid }
    }

    /// `{"type":"config","bindings":[{"action","hid","style"}...]}`
    func configMessageData() throws -> Data {
        try JSONEncoder().encode(ConfigMessage(bindings: entries))
    }

    func configMessageText() -> String? {
        guard let data = try? configMessageData() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct ConfigMessage: Encodable {
        let type = "config"
        let bindings: [BlindBinding]
    }
}

/// 合図の保存先。UserDefaults は差し替えられる(テストは使い捨ての suite を渡す)。
struct BlindBindingsStore {
    static let key = "blind.bindings.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 無い・壊れている場合は空。
    func load() -> BlindBindings {
        guard let data = defaults.data(forKey: Self.key),
              let bindings = try? JSONDecoder().decode(BlindBindings.self, from: data) else {
            return BlindBindings()
        }
        return bindings
    }

    func save(_ bindings: BlindBindings) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
