import CoreBluetooth
import Foundation
import Security
import UIKit

/// 小さな受信ログ。Library/Caches 内の専用フォルダに置き、バックアップと「ファイル」アプリの共有から外す。
/// 内容は番号・押下か離しか・アプリの状態・間隔・cue だけ(キーの中身は書かない)。64 KB で 1 世代だけ回す。
enum BridgeWakeLog {
    static let maximumBytes = 64 * 1024
    static let fileName = "bridge-wake.log"
    static let folderName = "BridgeLog"

    static func folderURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(folderName, isDirectory: true)
    }

    static func url() -> URL? {
        folderURL()?.appendingPathComponent(fileName)
    }

    /// ロック中の裏でも書けるよう、最初のロック解除のあとから書ける保護にする。
    private static var attributes: [FileAttributeKey: Any] { [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication] }

    private static func prepareFolder() -> URL? {
        guard var folder = folderURL() else { return nil }
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
        }
        try? manager.setAttributes(attributes, ofItemAtPath: folder.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }

    static func append(_ line: String) {
        guard prepareFolder() != nil, let url = url(), let data = (line + "\n").data(using: .utf8) else { return }
        let manager = FileManager.default
        if let info = try? manager.attributesOfItem(atPath: url.path),
           let size = info[.size] as? Int, size >= maximumBytes {
            let old = url.appendingPathExtension("1")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: attributes)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// 記録を全部消す。前の版が Documents に置いた分も消す。
    static func clear() {
        let manager = FileManager.default
        if let folder = folderURL() { try? manager.removeItem(at: folder) }
        if let docs = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let legacy = docs.appendingPathComponent(fileName)
            try? manager.removeItem(at: legacy)
            try? manager.removeItem(at: legacy.appendingPathExtension("1"))
        }
    }
}

/// 固定した接続先の識別子。識別子は秘密ではないが、書き換えられにくいよう Keychain に置く。
enum BridgePinStore {
    private static let service = "tsukaima.bridge"
    private static let account = "pinned-peripheral"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> UUID? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: text)
    }

    static func save(_ id: UUID) {
        clear()
        var item = base
        item[kSecValueData as String] = Data(id.uuidString.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(base as CFDictionary)
    }
}

/// ESP32 ブリッジの CoreBluetooth central。`start()` を呼ぶまで CBCentralManager を作らない(権限確認を出さないため)。
@MainActor
final class BridgeCentral: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = BridgeCentral()

    static let restoreIdentifier = "tsukaima.bridge"
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
    @Published private(set) var kbState: BridgeKbState = .boot
    @Published private(set) var blind: Bool?
    @Published private(set) var hidGate: Bool?
    @Published private(set) var battery: Int?
    @Published private(set) var missedPackets = 0
    @Published private(set) var lastReceipt: Date?
    @Published private(set) var records: [BridgePacketRecord] = []
    /// 固定した接続先(Keychain)。nil の間は、一覧に出すだけで自動ではつながない。
    @Published private(set) var pinnedID: UUID?
    @Published private(set) var discovered: [BridgeDiscovered] = []
    /// 1 秒あたりの上限を超えて捨てた受信数。
    @Published private(set) var rateDropped = 0

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
    /// 購読が完了した特性の UUID(固定済みの 1 台について)。配送の判定に使う。
    private var subscribedUUIDs: Set<String> = []
    private var modeSubscribed = false
    private var tracker = SeqTracker()
    private var limiter = BridgeRateLimiter()
    /// 一覧の機器の実体(つなぐときに必要。保持しないと CoreBluetooth が解放する)。
    private var candidates: [UUID: CBPeripheral] = [:]
    private var lastUptime: TimeInterval?
    private var nextRecordID = 0
    private var pingTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundEnd: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    /// Blind が入った後に、HID ゲートを閉じる要求を 1 度だけ送るための記録。
    private var pendingHidGateOff = false
    private let isoFormatter = ISO8601DateFormatter()

    private static var serviceID: CBUUID { CBUUID(string: BridgeGATT.serviceUUID) }
    private static var keysID: CBUUID { CBUUID(string: BridgeGATT.keysUUID) }
    private static var modeID: CBUUID { CBUUID(string: BridgeGATT.modeUUID) }
    private static var controlID: CBUUID { CBUUID(string: BridgeGATT.controlUUID) }

    override private init() {
        super.init()
        syncPin()
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
        endBackgroundTask()
        discovered = []
        candidates = [:]
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
        // つながっていなければ、購読できた時に閉じる要求を送る。
        pendingHidGateOff = !on && !(connected && subscribed)
        write(.hidGate(on))
    }

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        self.central = central
        isRunning = true
        startPingTimer()
        // 固定済みの 1 台だけを引き取る。別の機器が戻ってきたら切る。
        for restored in (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? [] {
            if BridgePinPolicy.decide(pinned: readPin(), candidate: restored.identifier) == .connect {
                adopt(restored)
            } else {
                central.cancelPeripheralConnection(restored)
            }
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
        consider(peripheral, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard authorize(peripheral) else { return }
        connected = true
        tracker.reset()
        lastUptime = nil
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard authorize(peripheral) else { return }
        resetLink()
        reconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard authorize(peripheral) else { return }
        resetLink()
        reconnect(peripheral)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard authorize(peripheral), error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else { return }
        peripheral.discoverCharacteristics([Self.keysID, Self.modeID, Self.controlID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard authorize(peripheral), error == nil,
              service.uuid == Self.serviceID, peripheral.services?.contains(where: { $0 === service }) == true else { return }
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
        guard authorize(peripheral), characteristic.service?.uuid == Self.serviceID else { return }
        // 暗号化が必須の特性は、ペアリング前だと購読に失敗する(error)。その間は subscribed にしない。
        let on = error == nil && characteristic.isNotifying
        if characteristic.uuid == Self.keysID { keysSubscribed = on }
        if characteristic.uuid == Self.modeID { modeSubscribed = on }
        let both = keysSubscribed && modeSubscribed
        subscribedUUIDs = Set([keysSubscribed ? BridgeGATT.keysUUID : nil, modeSubscribed ? BridgeGATT.modeUUID : nil].compactMap { $0 })
        if both && !subscribed {
            subscribed = true
            sendConfig()
            if pendingHidGateOff { sendHidGate(false) }
        } else if !both {
            subscribed = false
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // 注意: CoreBluetooth には「この通知が暗号化されたリンクで来たか」を調べる API が無い。
        // 暗号化と MITM 認証(DEC-8)は、ファーム側の特性の権限(暗号化必須・認証必須)で必ず強制すること。
        guard authorize(peripheral), error == nil, let data = characteristic.value else { return }
        guard deliveryAllowed(peripheral, characteristic) else { return }
        if characteristic.uuid == Self.keysID {
            if let packet = KeysPacket(data: data) { handle(packet, from: peripheral, characteristic: characteristic) }
        } else if characteristic.uuid == Self.modeID {
            if let packet = ModePacket(data: data) { handle(packet) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // 書き込みの応答。固定外の機器からは何も受けない(先頭の検査だけ)。
        _ = authorize(peripheral)
    }

    // MARK: 内部

    private func discover() {
        if let peripheral {
            resume(peripheral)
            return
        }
        let connectedOnes = central?.retrieveConnectedPeripherals(withServices: [Self.serviceID]) ?? []
        for one in connectedOnes {
            if consider(one, rssi: 0, viaRetrieveConnected: true) { return }
        }
        if let pin = readPin(), let known = central?.retrievePeripherals(withIdentifiers: [pin]).first {
            if consider(known, rssi: 0) { return }
        }
        // 前面でも裏でも、サービス UUID を指定した走査だけを使う。固定がないときは、一覧に出すだけ。
        central?.scanForPeripherals(withServices: [Self.serviceID], options: nil)
        scanning = true
    }

    /// 固定の読み出しは、ここ 1 か所だけ(Keychain が正本。キャッシュは使わない)。
    /// 読めない・無い・壊れている場合は nil = 「固定なし」(どの経路でも配送しない)。
    private func readPin() -> UUID? {
        BridgePinStore.load()
    }

    /// 画面用の写し(published)を、正本に合わせる。判定には使わない。
    private func syncPin() {
        pinnedID = readPin()
    }

    /// 委譲メソッドの先頭の検査。固定と一致しなければ直ちに切断し、状態を捨てて false。
    private func authorize(_ target: CBPeripheral) -> Bool {
        let pin = readPin()
        if pinnedID != pin { pinnedID = pin }
        if BridgePinPolicy.decide(pinned: pin, candidate: target.identifier) == .connect { return true }
        enforceDisconnect(target)
        return false
    }

    private func enforceDisconnect(_ target: CBPeripheral) {
        central?.cancelPeripheralConnection(target)
        if peripheral?.identifier == target.identifier {
            peripheral = nil
            resetLink()
            tracker.reset()
            lastUptime = nil
        }
    }

    /// 配送の判定(固定・出どころのサービス・購読済みの特性)。切断が必要なら切る。
    private func deliveryAllowed(_ source: CBPeripheral, _ characteristic: CBCharacteristic) -> Bool {
        let decision = BridgePinPolicy.decideDelivery(
            pinned: readPin(),
            peripheral: source.identifier,
            service: characteristic.service?.uuid.uuidString,
            characteristic: characteristic.uuid.uuidString,
            subscribed: subscribedUUIDs
        )
        switch decision {
        case .deliver:
            // 現在つないでいる 1 台と同じ実体であることも確かめる。
            return peripheral?.identifier == source.identifier
        case .drop:
            return false
        case .disconnect:
            enforceDisconnect(source)
            return false
        }
    }

    /// 見つけた機器を判定する。固定済みならつなぐ(true)。固定がなければ一覧に足すだけ。別の機器は無視する。
    @discardableResult
    private func consider(_ target: CBPeripheral, rssi: Int, viaRetrieveConnected: Bool = false) -> Bool {
        switch BridgePinPolicy.decide(pinned: readPin(), candidate: target.identifier) {
        case .connect:
            found = true
            if viaRetrieveConnected { foundViaRetrieveConnected = true }
            connect(target)
            return true
        case .listOnly:
            found = true
            if viaRetrieveConnected { foundViaRetrieveConnected = true }
            candidates[target.identifier] = target
            let name = String((target.name ?? "(名前なし)").prefix(40))
            let entry = BridgeDiscovered(id: target.identifier, name: name, rssi: rssi)
            if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
                discovered[index] = entry
            } else if discovered.count < BridgeDiscovered.maximumCount {
                discovered.append(entry)
            }
            return false
        case .ignore:
            return false
        }
    }

    /// 本人が「この機器につなぐ」を押したときだけ、接続先を固定する。
    func pin(_ id: UUID) {
        guard let target = candidates[id] else { return }
        BridgePinStore.save(id)
        syncPin()
        discovered = []
        candidates = [:]
        connect(target)
    }

    /// 固定を解いて、つながりを切り、記録も消す。
    func unpin() {
        BridgePinStore.clear()
        syncPin()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        resetLink()
        found = false
        foundViaRetrieveConnected = false
        tracker.reset()
        lastUptime = nil
        clearRecords()
        if isRunning, !Self.isMock, central?.state == .poweredOn { discover() }
    }

    /// 記録(画面の分とファイル)を消す。
    func clearRecords() {
        records = []
        missedPackets = 0
        rateDropped = 0
        lastReceipt = nil
        BridgeWakeLog.clear()
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
    }

    private func connect(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        central?.stopScan()
        scanning = false
        central?.connect(target, options: nil)  // 保留中の接続は、つながるまで残る
    }

    private func reconnect(_ target: CBPeripheral) {
        guard isRunning, authorize(target), central?.state == .poweredOn else { return }
        central?.connect(target, options: nil)
    }

    private func resetLink() {
        connected = false
        subscribed = false
        keysSubscribed = false
        modeSubscribed = false
        subscribedUUIDs = []
        keysCharacteristic = nil
        modeCharacteristic = nil
        controlCharacteristic = nil
    }

    private func write(_ packet: ControlPacket) {
        guard let peripheral, let controlCharacteristic, connected, authorize(peripheral) else { return }
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

    private func handle(_ packet: KeysPacket, from source: CBPeripheral, characteristic: CBCharacteristic) {
        let now = ProcessInfo.processInfo.systemUptime
        let appState = currentAppState()
        switch limiter.check(at: now) {
        case .accept: break
        case .dropFirst:
            rateDropped = limiter.totalDropped
            BridgeWakeLog.append("\(isoFormatter.string(from: Date())) rate_limit dropped>\(limiter.limit)/s")
            return
        case .drop:
            rateDropped = limiter.totalDropped
            return
        }
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

        // ESP32 が HID を前面のアプリへ流している間(hid_gate=true)は、前面なら直接のキーと二重になるので届けない。
        let doubled = hidGate == true && appState == .active
        // 配送の時点で、もう一度、固定・出どころ・購読を検査する(固定が解除・変更されていれば、ここで切って捨てる)。
        if deliver, !doubled, authorize(source), deliveryAllowed(source, characteristic) {
            onKeys?([BlindKeyEvent(hid: Int(packet.hid), down: packet.down, t: now, char: nil)])
        }
    }

    /// 起こされた間だけ、短く(2 秒)実行時間を延ばす。連続で来たら終了を後ろへずらす。
    private func holdBackgroundTask() {
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "tsukaima.bridge.keys") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
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
