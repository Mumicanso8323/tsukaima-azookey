import CoreBluetooth
import Foundation
import UIKit

/// 小さな受信ログ(Documents/bridge-wake.log)。キーの中身は書かない。64 KB で 1 世代だけ回す。
enum BridgeWakeLog {
    static let maximumBytes = 64 * 1024
    static let fileName = "bridge-wake.log"

    static func url() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    static func append(_ line: String) {
        guard let url = url(), let data = (line + "\n").data(using: .utf8) else { return }
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size >= maximumBytes {
            let old = url.appendingPathExtension("1")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// ESP32 ブリッジの CoreBluetooth central。`start()` を呼ぶまで CBCentralManager を作らない(権限確認を出さないため)。
@MainActor
final class BridgeCentral: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = BridgeCentral()

    static let restoreIdentifier = "tsukaima.bridge"
    static let peripheralDefaultsKey = "bridge.peripheral.id"
    static let enabledDefaultsKey = "bridge.enabled"
    static let ringCapacity = 200
    static let pingInterval: TimeInterval = 20

    /// UI テスト用: --bridge-mock で CoreBluetooth に触れず、状態を mock にする。
    static var isMock: Bool { ProcessInfo.processInfo.arguments.contains("--bridge-mock") }

    // 画面用の状態
    @Published private(set) var bluetooth: BridgeRadioState = .notStarted
    @Published private(set) var isRunning = false
    @Published private(set) var scanning = false
    /// TEST-3: 周辺機器を見つけた(HID として iOS が持っていても retrieveConnectedPeripherals で見えたか)。
    @Published private(set) var found = false
    @Published private(set) var foundViaRetrieveConnected = false
    @Published private(set) var connected = false
    @Published private(set) var subscribed = false
    @Published private(set) var kbState: BridgeKbState = .unknown
    @Published private(set) var blind: Bool?
    @Published private(set) var hidGate: Bool?
    @Published private(set) var battery: Int?
    @Published private(set) var missedPackets = 0
    @Published private(set) var lastReceipt: Date?
    @Published private(set) var records: [BridgePacketRecord] = []

    /// 受けたキー。既存の BlindLink.push と同じ経路へ流す。
    var onKeys: (([BlindKeyEvent]) -> Void)?
    /// TEST-4: 前面以外で受けたとき、合図音を試す(結果を記録する)。nil なら試さない。
    var cueAttempt: (@MainActor () -> BridgeCue)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var keysCharacteristic: CBCharacteristic?
    private var modeCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var keysSubscribed = false
    private var modeSubscribed = false
    private var tracker = SeqTracker()
    private var lastUptime: TimeInterval?
    private var nextRecordID = 0
    private var pingTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundEnd: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let isoFormatter = ISO8601DateFormatter()

    private static var serviceID: CBUUID { CBUUID(string: BridgeGATT.serviceUUID) }
    private static var keysID: CBUUID { CBUUID(string: BridgeGATT.keysUUID) }
    private static var modeID: CBUUID { CBUUID(string: BridgeGATT.modeUUID) }
    private static var controlID: CBUUID { CBUUID(string: BridgeGATT.controlUUID) }

    override private init() {
        super.init()
    }

    /// 起動時に呼ぶ。前に本人が有効にしていたときだけ central を作り、復元を受けられるようにする(それ以外は何も作らない)。
    static func resumeIfEnabled() {
        guard !isMock, UserDefaults.standard.bool(forKey: enabledDefaultsKey) else { return }
        shared.start()
    }

    // MARK: 開始・停止

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if Self.isMock {
            bluetooth = .mock
            return
        }
        defaults.set(true, forKey: Self.enabledDefaultsKey)
        startPingTimer()
        if let central {
            if central.state == .poweredOn { discover() }
        } else {
            central = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [
                    CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                    CBCentralManagerOptionShowPowerAlertKey: false,
                ]
            )
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if Self.isMock {
            bluetooth = .notStarted
            return
        }
        defaults.set(false, forKey: Self.enabledDefaultsKey)
        pingTimer?.invalidate()
        pingTimer = nil
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetLink()
        peripheral = nil
        central = nil
        bluetooth = .notStarted
    }

    /// 合図の設定を ESP32 へ送り直す(つながっていなければ何もしない)。
    func sendConfig() {
        write(.config(BlindBindingsStore().load().entries))
    }

    func sendHidGate(_ on: Bool) {
        write(.hidGate(on))
    }

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        self.central = central
        isRunning = true
        startPingTimer()
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            adopt(restored)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown: bluetooth = .unknown
        case .resetting: bluetooth = .resetting
        case .unsupported: bluetooth = .unsupported
        case .unauthorized: bluetooth = .unauthorized
        case .poweredOff: bluetooth = .poweredOff
        case .poweredOn: bluetooth = .poweredOn
        @unknown default: bluetooth = .unknown
        }
        guard central.state == .poweredOn else {
            scanning = false
            resetLink()
            return
        }
        if isRunning { discover() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        found = true
        central.stopScan()
        scanning = false
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        tracker.reset()
        lastUptime = nil
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resetLink()
        reconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetLink()
        reconnect(peripheral)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else { return }
        peripheral.discoverCharacteristics([Self.keysID, Self.modeID, Self.controlID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.keysID:
                keysCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.modeID:
                modeCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.controlID:
                controlCharacteristic = characteristic
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let on = error == nil && characteristic.isNotifying
        if characteristic.uuid == Self.keysID { keysSubscribed = on }
        if characteristic.uuid == Self.modeID { modeSubscribed = on }
        let both = keysSubscribed && modeSubscribed
        if both && !subscribed {
            subscribed = true
            sendConfig()
        } else if !both {
            subscribed = false
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == Self.keysID {
            if let packet = KeysPacket(data: data) { handle(packet) }
        } else if characteristic.uuid == Self.modeID {
            if let packet = ModePacket(data: data) { handle(packet) }
        }
    }

    // MARK: 内部

    private func discover() {
        if let peripheral {
            resume(peripheral)
            return
        }
        let connectedOnes = central?.retrieveConnectedPeripherals(withServices: [Self.serviceID]) ?? []
        if let first = connectedOnes.first {
            found = true
            foundViaRetrieveConnected = true
            connect(first)
            return
        }
        if let text = defaults.string(forKey: Self.peripheralDefaultsKey),
           let id = UUID(uuidString: text),
           let known = central?.retrievePeripherals(withIdentifiers: [id]).first {
            found = true
            connect(known)
            return
        }
        // 前面でも裏でも、サービス UUID を指定した走査だけを使う。
        central?.scanForPeripherals(withServices: [Self.serviceID], options: nil)
        scanning = true
    }

    /// 復元・再開で、すでに持っている周辺機器の続きから進める。
    private func resume(_ peripheral: CBPeripheral) {
        found = true
        peripheral.delegate = self
        switch peripheral.state {
        case .connected:
            connected = true
            peripheral.discoverServices([Self.serviceID])
        case .connecting:
            break
        default:
            central?.connect(peripheral, options: nil)
        }
    }

    private func adopt(_ restored: CBPeripheral) {
        peripheral = restored
        restored.delegate = self
        defaults.set(restored.identifier.uuidString, forKey: Self.peripheralDefaultsKey)
    }

    private func connect(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        defaults.set(target.identifier.uuidString, forKey: Self.peripheralDefaultsKey)
        central?.stopScan()
        scanning = false
        central?.connect(target, options: nil)  // 保留中の接続は、つながるまで残る
    }

    private func reconnect(_ target: CBPeripheral) {
        guard isRunning, central?.state == .poweredOn else { return }
        central?.connect(target, options: nil)
    }

    private func resetLink() {
        connected = false
        subscribed = false
        keysSubscribed = false
        modeSubscribed = false
        keysCharacteristic = nil
        modeCharacteristic = nil
        controlCharacteristic = nil
    }

    private func write(_ packet: ControlPacket) {
        guard let peripheral, let controlCharacteristic, connected else { return }
        peripheral.writeValue(packet.encode(), for: controlCharacteristic, type: .withResponse)
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pingTick() }
        }
    }

    private func pingTick() {
        guard subscribed, UIApplication.shared.applicationState == .active else { return }
        write(.ping)
    }

    private func currentAppState() -> BridgeAppState {
        switch UIApplication.shared.applicationState {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .background
        }
    }

    private func handle(_ packet: ModePacket) {
        kbState = packet.kbState
        blind = packet.blind
        hidGate = packet.hidGate
        battery = packet.battery
    }

    private func handle(_ packet: KeysPacket) {
        let now = ProcessInfo.processInfo.systemUptime
        let appState = currentAppState()
        if appState != .active { holdBackgroundTask() }

        let result = tracker.observe(packet.seq)
        var missed = 0
        var deliver = true
        switch result {
        case .first, .inOrder: break
        case .gap(let count): missed = count
        case .duplicate, .stale: deliver = false
        }

        var cue = BridgeCue.notApplicable
        if appState != .active, deliver, let cueAttempt { cue = cueAttempt() }

        let delta = lastUptime.map { Int(((now - $0) * 1000).rounded()) }
        lastUptime = now
        let record = BridgePacketRecord(
            id: nextRecordID, seq: packet.seq, down: packet.down, appState: appState,
            deltaMs: delta, missedBefore: missed, cue: cue
        )
        nextRecordID += 1
        records.append(record)
        if records.count > Self.ringCapacity { records.removeFirst(records.count - Self.ringCapacity) }
        missedPackets = tracker.totalMissed
        lastReceipt = Date()
        BridgeWakeLog.append(record.logLine(iso: isoFormatter.string(from: Date())))

        if deliver {
            onKeys?([BlindKeyEvent(hid: Int(packet.hid), down: packet.down, t: now, char: nil)])
        }
    }

    /// 起こされた間だけ、短く(2 秒)実行時間を延ばす。連続で来たら終了を後ろへずらす。
    private func holdBackgroundTask() {
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "tsukaima.bridge.keys") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        backgroundEnd?.cancel()
        backgroundEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        backgroundEnd?.cancel()
        backgroundEnd = nil
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
