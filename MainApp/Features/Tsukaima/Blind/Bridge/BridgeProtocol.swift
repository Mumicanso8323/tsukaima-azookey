import Foundation

/// ESP32 ブリッジの GATT の取り決め(docs/esp32-bridge.md の DEC-4)。CoreBluetooth には依存しない純粋なロジック。
enum BridgeGATT {
    // TODO: 下の UUID は仮の値。firmware/esp32-blind-bridge/protocol.h の UUID と必ず同じにする(ここ 1 か所だけで定義する)。
    static let serviceUUID = "7A5E0001-B11D-4C0F-9A2E-5B7D00000001"
    static let keysUUID = "7A5E0002-B11D-4C0F-9A2E-5B7D00000001"
    static let controlUUID = "7A5E0003-B11D-4C0F-9A2E-5B7D00000001"
    static let modeUUID = "7A5E0004-B11D-4C0F-9A2E-5B7D00000001"
}

/// `keys` の notify: `[seq u16 LE][hid u16 LE][down u8][mods u8]` = 6 バイト。
struct KeysPacket: Equatable, Sendable {
    static let length = 6
    let seq: UInt16
    let hid: UInt16
    let down: Bool
    let mods: UInt8

    /// 長さが 6 でなければ nil。
    init?(data: Data) {
        let b = [UInt8](data)
        guard b.count == Self.length else { return nil }
        seq = UInt16(b[0]) | UInt16(b[1]) << 8
        hid = UInt16(b[2]) | UInt16(b[3]) << 8
        down = b[4] != 0
        mods = b[5]
    }

    init(seq: UInt16, hid: UInt16, down: Bool, mods: UInt8) {
        self.seq = seq
        self.hid = hid
        self.down = down
        self.mods = mods
    }
}

/// キーボードの接続状態。数値はファームの kb_state と合わせる。
/// TODO: firmware/esp32-blind-bridge/protocol.h が決まったら数値を突き合わせる(いまは仮の割り当て)。
enum BridgeKbState: UInt8, Equatable, Sendable, CaseIterable {
    case unknown = 0
    case notFound = 1
    case bleFound = 2
    case classicOnly = 3
    case connected = 4
    case ready = 5
    case sleeping = 6

    /// 未知の値は unknown に丸める。
    init(raw: UInt8) {
        self = BridgeKbState(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .unknown: "不明"
        case .notFound: "見つからない"
        case .bleFound: "BLE を発見"
        case .classicOnly: "Classic のみ(未対応)"
        case .connected: "接続した"
        case .ready: "使える"
        case .sleeping: "スリープ中"
        }
    }
}

/// `mode` の notify: `[blind u8][hid_gate u8][kb_state u8][battery u8 (0xFF=不明)][seq u16 LE]` = 6 バイト。
struct ModePacket: Equatable, Sendable {
    static let length = 6
    static let unknownBattery: UInt8 = 0xFF
    let blind: Bool
    let hidGate: Bool
    let kbState: BridgeKbState
    /// 不明なら nil。
    let battery: Int?
    let seq: UInt16

    init?(data: Data) {
        let b = [UInt8](data)
        guard b.count == Self.length else { return nil }
        blind = b[0] != 0
        hidGate = b[1] != 0
        kbState = BridgeKbState(raw: b[2])
        battery = b[3] == Self.unknownBattery ? nil : Int(b[3])
        seq = UInt16(b[4]) | UInt16(b[5]) << 8
    }
}

/// `control` への書き込み。
enum ControlPacket: Equatable, Sendable {
    static let maximumBindings = 16
    static let opConfig: UInt8 = 0x01
    static let opHidGate: UInt8 = 0x02
    static let opPing: UInt8 = 0x03

    case config([BlindBinding])
    case hidGate(Bool)
    case ping

    /// config: `[0x01][count][count × {action u8, hid u16 LE, style u8}]`。17 件目以降は切り捨てる。
    func encode() -> Data {
        switch self {
        case .config(let bindings):
            let list = bindings.prefix(Self.maximumBindings)
            var bytes: [UInt8] = [Self.opConfig, UInt8(list.count)]
            for binding in list {
                let hid = UInt16(truncatingIfNeeded: binding.hid)
                bytes.append(Self.actionCode(binding.action))
                bytes.append(UInt8(hid & 0xFF))
                bytes.append(UInt8(hid >> 8))
                bytes.append(Self.styleCode(binding.style))
            }
            return Data(bytes)
        case .hidGate(let on):
            return Data([Self.opHidGate, on ? 1 : 0])
        case .ping:
            return Data([Self.opPing])
        }
    }

    static func actionCode(_ action: BlindAction) -> UInt8 {
        switch action {
        case .toggle: 1
        case .mode: 2
        case .voice: 3
        case .read: 4
        }
    }

    static func styleCode(_ style: BlindStyle) -> UInt8 {
        switch style {
        case .double: 1
        case .hold: 2
        case .tap: 3
        }
    }
}

/// seq(u16、折り返しあり)の欠落・重複の検出。
struct SeqTracker: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case first
        case inOrder
        /// `missed` 個ぶん飛んだ。
        case gap(missed: Int)
        /// 直前と同じ seq。
        case duplicate
        /// 古い seq(順序の入れ替わり)。数えず、基準も進めない。
        case stale
    }

    private(set) var last: UInt16?
    private(set) var totalMissed = 0

    init() {}

    mutating func observe(_ seq: UInt16) -> Result {
        guard let previous = last else {
            last = seq
            return .first
        }
        let diff = seq &- previous
        if diff == 0 { return .duplicate }
        if diff >= 0x8000 { return .stale }
        last = seq
        if diff == 1 { return .inOrder }
        let missed = Int(diff) - 1
        totalMissed += missed
        return .gap(missed: missed)
    }

    mutating func reset() {
        last = nil
        totalMissed = 0
    }
}

/// 無線の状態(画面用)。
enum BridgeRadioState: Equatable, Sendable {
    case notStarted, unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn, mock

    var label: String {
        switch self {
        case .notStarted: "未開始"
        case .unknown: "不明"
        case .resetting: "リセット中"
        case .unsupported: "非対応"
        case .unauthorized: "許可なし"
        case .poweredOff: "Bluetooth オフ"
        case .poweredOn: "オン"
        case .mock: "mock"
        }
    }
}

/// 受信時のアプリの状態。
enum BridgeAppState: String, Equatable, Sendable {
    case active, inactive, background

    var label: String {
        switch self {
        case .active: "前面"
        case .inactive: "非アクティブ"
        case .background: "裏"
        }
    }
}

/// 前面以外で受けたときの合図音の試行結果。
enum BridgeCue: String, Equatable, Sendable {
    case notApplicable = "-"
    case ok, fail, skipped
}

/// 受信 1 件の記録。キーの中身(hid)は持たない。
struct BridgePacketRecord: Equatable, Sendable, Identifiable {
    let id: Int
    let seq: UInt16
    let down: Bool
    let appState: BridgeAppState
    /// 直前のパケットからの経過(ミリ秒)。最初は nil。
    let deltaMs: Int?
    /// この直前に抜けた個数。
    let missedBefore: Int
    let cue: BridgeCue

    /// `seq=… down=… app=… delta_ms=… missed=… cue=…`。時刻は呼び出し側が付ける。
    func logLine(iso: String) -> String {
        "\(iso) seq=\(seq) down=\(down ? 1 : 0) app=\(appState.rawValue) delta_ms=\(deltaMs.map(String.init) ?? "-") missed=\(missedBefore) cue=\(cue.rawValue)"
    }
}

/// TEST-4 の要約: 前面以外で受けたパケットの集計。
struct BridgeLockSummary: Equatable, Sendable {
    let count: Int
    let maxDeltaMs: Int?
    let averageDeltaMs: Int?
    let missed: Int
    let cueOK: Int
    let cueFail: Int
    let cueSkipped: Int

    init(records: [BridgePacketRecord]) {
        let away = records.filter { $0.appState != .active }
        count = away.count
        let deltas = away.compactMap(\.deltaMs)
        maxDeltaMs = deltas.max()
        averageDeltaMs = deltas.isEmpty ? nil : deltas.reduce(0, +) / deltas.count
        missed = away.reduce(0) { $0 + $1.missedBefore }
        cueOK = away.filter { $0.cue == .ok }.count
        cueFail = away.filter { $0.cue == .fail }.count
        cueSkipped = away.filter { $0.cue == .skipped }.count
    }

    var text: String {
        "裏・ロック中の受信 \(count) 件 / 間隔 最大 \(maxDeltaMs.map(String.init) ?? "-") ms・平均 \(averageDeltaMs.map(String.init) ?? "-") ms / 欠落 \(missed) / 合図音 ok \(cueOK)・fail \(cueFail)・skipped \(cueSkipped)"
    }
}
