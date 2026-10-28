import Foundation

/// 返事の出し方(docs/blind-decouple.md DEC-6)。サーバーには持たせず、アプリが保存して hello で宣言する。
enum BlindOutputMode: String, CaseIterable, Sendable {
    case voice
    case text
    case both

    /// voice → text → both → voice
    func next() -> BlindOutputMode {
        switch self {
        case .voice: return .text
        case .text: return .both
        case .both: return .voice
        }
    }

    /// 壊れた・無い保存値は、従来どおりの voice に倒す。
    static func restored(from raw: String?) -> BlindOutputMode {
        guard let raw, let mode = BlindOutputMode(rawValue: raw) else { return .voice }
        return mode
    }

    var playsAudio: Bool { self != .text }
    /// 返事の到着を既定で振動させるか(both は設定でオン)。
    var vibratesByDefault: Bool { self == .text }
}

/// 出し方の保存先。UserDefaults は差し替えられる(テスト・UI テストは使い捨ての suite)。
struct BlindOutputModeStore {
    static let key = "blind.reply_output"
    static let bothHapticsKey = "blind.both_haptics"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> BlindOutputMode {
        BlindOutputMode.restored(from: defaults.string(forKey: Self.key))
    }

    func save(_ mode: BlindOutputMode) {
        defaults.set(mode.rawValue, forKey: Self.key)
    }

    /// BOTH の到着振動(既定オフ)。
    func loadBothHaptics() -> Bool {
        defaults.bool(forKey: Self.bothHapticsKey)
    }

    func saveBothHaptics(_ on: Bool) {
        defaults.set(on, forKey: Self.bothHapticsKey)
    }
}
