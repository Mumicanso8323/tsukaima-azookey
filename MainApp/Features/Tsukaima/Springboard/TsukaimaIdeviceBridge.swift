import Darwin
import Foundation
import IDevice  // fork(Mumicanso8323/idevice)の C FFI 一式 + 同梱の libplist。
                // IDevice.xcframework の各スライスに module.modulemap が同梱されているので
                // (docs/tsukaima-springboard-icon-integration.md §2)、bridging header は不要。

/// idevice fork の SpringBoardServices FFI の薄いラッパー。
///
/// 接続方式(docs/tsukaima-springboard-icon-integration.md §7):
/// SideStore / StikDebug(StosDebug)と同じく、**端末内だけで完結する VPN**(StosVPN、旧称 LocalDevVPN。
/// SideStore 利用者は導入済み)を ON にして、その仮想アドレス `10.7.0.1` の lockdown ポート `62078` に
/// TCP で繋ぐ。StosVPN は utun に `10.7.0.0/24` を割り当て、`10.7.0.1` 宛てのパケットを
/// 自分自身(`10.7.0.0`)宛てに書き換えて戻すだけの仕組みなので(StosVPN の PacketTunnelProvider)、
/// Wi-Fi も PC も要らない。VPN が OFF だと `10.7.0.1` への経路が無く、接続は失敗する
/// (先に `getifaddrs` で `10.7.0.0/24` のインターフェースがあるかを確かめて、無ければ案内を出す)。
///
/// TCP 越しの lockdownd は heartbeat(com.apple.mobile.heartbeat の marco/polo)を維持していないと
/// サービスの開始を拒む・切断することがあるため、StosDebug と同じくセッション中は別スレッドで
/// heartbeat を回し続ける(`TsukaimaHeartbeatKeeper`)。
///
/// すべて同期・ブロッキング呼び出し(Rust 側が内部でブロックする)。呼び出し側は必ず
/// `Task.detached` などバックグラウンドから呼ぶこと(TsukaimaSpringboardLayoutView 参照)。
/// ペアリング記録の中身は絶対にログ・画面に出さない — FFI のエラーは定型文に丸め、message は読まない。
enum TsukaimaIdeviceError: LocalizedError {
    case vpnOff
    case pairingFileMissing
    case pairingFileInvalid
    case connectionFailed
    case heartbeatFailed
    case serviceFailed
    case plistDecodeFailed
    case plistEncodeFailed
    case setRejected

    var errorDescription: String? {
        switch self {
        case .vpnOff:
            "端末内 VPN(StosVPN / LocalDevVPN)が OFF です。StosVPN アプリを開いて接続してから、もう一度試してください。"
        case .pairingFileMissing:
            "ペアリングファイルがありません。SideStore から取り込むか、ファイルを選んで取り込んでください。"
        case .pairingFileInvalid:
            "ペアリングファイルを読み取れませんでした(SideStore で使えているものを入れ直してください)"
        case .connectionFailed:
            "この端末の lockdownd(10.7.0.1:62078)に接続できませんでした。StosVPN が接続中か、ペアリングファイルがこの端末のものかを確認してください。"
        case .heartbeatFailed:
            "接続は出来ましたが heartbeat を開始できませんでした(ペアリングファイルが古い可能性があります)"
        case .serviceFailed:
            "SpringBoard サービスに接続できませんでした"
        case .plistDecodeFailed:
            "応答を読み取れませんでした"
        case .plistEncodeFailed:
            "配置データを端末に送る形に変換できませんでした"
        case .setRejected:
            "端末が配置の書き換えを受け付けませんでした"
        }
    }
}

/// heartbeat(marco/polo)を別スレッドで回し続ける。StosDebug-Legacy の `establishHeartbeat` と同じ流儀。
/// クライアントの所有権はこのスレッドが持ち、ループ終了時に自分で解放する。
final class TsukaimaHeartbeatKeeper: @unchecked Sendable {
    private let client: OpaquePointer
    private let lock = NSLock()
    private var stopRequested = false
    private var failed = false
    private let finished = DispatchSemaphore(value: 0)

    init(client: OpaquePointer) {
        self.client = client
    }

    func start() {
        let thread = Thread { [self] in
            self.loop()
        }
        thread.name = "tsukaima-idevice-heartbeat"
        thread.qualityOfService = .utility
        thread.start()
    }

    var isHealthy: Bool {
        lock.lock(); defer { lock.unlock() }
        return !failed
    }

    /// 停止を要求し、スレッドが marco 待ちから抜けてクライアントを解放するまで待つ。
    /// 待ちきれなかったら false(呼び手は provider を解放せずに放置する = クラッシュよりリークを選ぶ)。
    func stop(timeout: TimeInterval) -> Bool {
        lock.lock()
        stopRequested = true
        lock.unlock()
        return finished.wait(timeout: .now() + timeout) == .success
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func markFailed() {
        lock.lock(); failed = true; lock.unlock()
    }

    private func loop() {
        // 端末は最初の marco で次の間隔を伝えてくる。待ち時間は「伝えられた間隔 + 余裕」にする
        // (idevice の tools/heartbeat_client.rs と同じ +5 秒)。
        var interval: UInt64 = 10
        while !shouldStop {
            var next: UInt64 = 0
            if let err = heartbeat_get_marco(client, interval, &next) {
                idevice_error_free(err)
                markFailed()
                break
            }
            interval = next + 5
            if let err = heartbeat_send_polo(client) {
                idevice_error_free(err)
                markFailed()
                break
            }
        }
        heartbeat_client_free(client)
        finished.signal()
    }
}

/// provider + heartbeat をまとめた 1 回分のセッション。`TsukaimaIdeviceBridge.withSession` からだけ使う。
final class TsukaimaIdeviceSession {
    fileprivate let provider: OpaquePointer
    fileprivate let heartbeat: TsukaimaHeartbeatKeeper
    /// fork の `springboard_services_connect` は接続失敗時に provider を自分で解放してしまう
    /// (ffi/src/springboardservices.rs の Err 側 `Box::from_raw(provider)`)。二重解放を避けるため、
    /// その経路を通ったら close() で provider を解放しない。
    private var providerDisowned = false

    fileprivate init(provider: OpaquePointer, heartbeat: TsukaimaHeartbeatKeeper) {
        self.provider = provider
        self.heartbeat = heartbeat
    }

    /// SpringBoardServices に繋いで `body` を実行する。client は body の間だけ有効。
    func withSpringboard<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var client: OpaquePointer?
        let rc = springboard_services_connect(provider, &client)
        if let rc {
            idevice_error_free(rc)
            providerDisowned = true
            throw heartbeat.isHealthy ? TsukaimaIdeviceError.serviceFailed : TsukaimaIdeviceError.heartbeatFailed
        }
        guard let client else { throw TsukaimaIdeviceError.serviceFailed }
        defer { springboard_services_free(client) }
        return try body(client)
    }

    fileprivate func close() {
        // heartbeat スレッドが marco 待ち(最長 interval 秒)から抜けるのを待ってから provider を解放する。
        // 待ちきれなければ provider は解放しない(解放後に触る事故を避ける)。
        let stopped = heartbeat.stop(timeout: 20)
        if stopped, !providerDisowned {
            idevice_provider_free(provider)
        }
    }
}

enum TsukaimaIdeviceBridge {
    /// StosVPN(旧 LocalDevVPN)の仮想アドレス。StikDebug / StosDebug / SideStore が使っているのと同じ値
    /// (StosVPN の PacketTunnelProvider: tunnelFakeIp = "10.7.0.1")。
    static let vpnHost = "10.7.0.1"
    /// lockdownd の待受ポート(idevice.h の `LOCKDOWN_PORT`、StosDebug も同じ)。
    /// StikDebug 最新版が使う 49152 は RemotePairing トンネル(`tunnel_create_rppairing`)用で、
    /// classic lockdown の SpringBoardServices には使わない。
    static let lockdownPort: UInt16 = 62078
    /// StosVPN が utun に付けるネットワーク(tunnelDeviceIp = "10.7.0.0", mask /24)。
    /// これが見えていれば VPN は ON とみなす。
    static let vpnNetworkPrefix: UInt32 = 0x0A07_0000  // 10.7.0.0
    static let vpnNetworkMask: UInt32 = 0xFFFF_FF00

    // MARK: VPN の状態

    /// 端末内 VPN(StosVPN)が ON か: `10.7.0.0/24` の IPv4 アドレスを持つインターフェースが存在するか。
    /// 他アプリの NE トンネルの状態は直接は問い合わせられないので、インターフェースの有無で判定する。
    static func isVPNInterfacePresent() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor {
            if let sa = ifa.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET {
                let raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let host = UInt32(bigEndian: raw)
                if host & vpnNetworkMask == vpnNetworkPrefix { return true }
            }
            cursor = ifa.pointee.ifa_next
        }
        return false
    }

    // MARK: セッション

    /// VPN 確認 → ペアリングファイル → TCP provider → heartbeat 開始 → body → 後始末、を同期で行う。
    static func withSession<T>(pairingFileData: Data, _ body: (TsukaimaIdeviceSession) throws -> T) throws -> T {
        guard isVPNInterfacePresent() else { throw TsukaimaIdeviceError.vpnOff }
        let session = try openSession(pairingFileData: pairingFileData)
        defer { session.close() }
        return try body(session)
    }

    private static func openSession(pairingFileData: Data) throws -> TsukaimaIdeviceSession {
        // 1) ペアリングファイルをバイト列から読む(ディスクパスをここに持ち込まない)
        var pairingFile: OpaquePointer?
        let pairingRC = pairingFileData.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
            idevice_pairing_file_from_bytes(raw.bindMemory(to: UInt8.self).baseAddress, UInt(raw.count), &pairingFile)
        }
        if let pairingRC {
            idevice_error_free(pairingRC)
            throw TsukaimaIdeviceError.pairingFileInvalid
        }
        guard let pairingFile else { throw TsukaimaIdeviceError.pairingFileInvalid }

        // 2) 10.7.0.1:62078 への TCP provider。
        //    「pairing_file is consumed」(idevice.h の Safety 注記)なので、成功・失敗を問わず
        //    ここで pairingFile を自分で free してはいけない(呼び先が引き取る契約)。
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = lockdownPort.bigEndian
        guard inet_pton(AF_INET, vpnHost, &addr.sin_addr) == 1 else { throw TsukaimaIdeviceError.connectionFailed }

        var provider: OpaquePointer?
        let providerRC = withUnsafePointer(to: &addr) { addrPtr -> UnsafeMutablePointer<IdeviceFfiError>? in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                "tsukaima".withCString { label in
                    idevice_tcp_provider_new(sa, pairingFile, label, &provider)
                }
            }
        }
        if let providerRC {
            idevice_error_free(providerRC)
            throw TsukaimaIdeviceError.connectionFailed
        }
        guard let provider else { throw TsukaimaIdeviceError.connectionFailed }

        // 3) heartbeat を繋いで別スレッドで回す(ここで初めて実際に lockdownd と通信する)。
        //    provider は borrow only。失敗したらここで解放する。
        var hbClient: OpaquePointer?
        let hbRC = heartbeat_connect(provider, &hbClient)
        if let hbRC {
            idevice_error_free(hbRC)
            idevice_provider_free(provider)
            throw TsukaimaIdeviceError.connectionFailed
        }
        guard let hbClient else {
            idevice_provider_free(provider)
            throw TsukaimaIdeviceError.heartbeatFailed
        }
        let keeper = TsukaimaHeartbeatKeeper(client: hbClient)
        keeper.start()
        return TsukaimaIdeviceSession(provider: provider, heartbeat: keeper)
    }

    // MARK: 読み取り

    /// 現在の配置を plist XML(Data)として返す。libimobiledevice の sbmanager と同じく formatVersion "2"
    /// で要求する(フォルダが入れ子の iconLists として返る形式)。
    static func readIconStateXML(pairingFileData: Data) throws -> Data {
        try withSession(pairingFileData: pairingFileData) { session in
            try session.withSpringboard { client in
                var result: UnsafeMutableRawPointer?
                let getRC = "2".withCString { version in
                    springboard_services_get_icon_state(client, version, &result)
                }
                if let getRC {
                    idevice_error_free(getRC)
                    throw TsukaimaIdeviceError.serviceFailed
                }
                guard let result else { throw TsukaimaIdeviceError.plistDecodeFailed }
                defer { plist_free(result) }
                return try plistToXML(result)
            }
        }
    }

    /// 読み取って型付きに解釈したものを返す(画面用)。
    static func readIconState(pairingFileData: Data) throws -> TsukaimaIconState {
        let xml = try readIconStateXML(pairingFileData: pairingFileData)
        return try TsukaimaIconLayout.parse(xml: xml)
    }

    // MARK: 書き込み

    /// plist XML(`readIconStateXML` が返した形、または `TsukaimaIconLayout.apply` の結果)をそのまま
    /// `setIconState` で端末に送る。`set_icon_state` は plist を clone するので、こちらで解放する。
    static func writeIconStateXML(_ xml: Data, pairingFileData: Data) throws {
        try withSession(pairingFileData: pairingFileData) { session in
            try session.withSpringboard { client in
                let node = try plistFromXML(xml)
                defer { plist_free(node) }
                if let setRC = springboard_services_set_icon_state(client, node) {
                    idevice_error_free(setRC)
                    throw TsukaimaIdeviceError.setRejected
                }
            }
        }
    }

    // MARK: plist 変換(C の木を自前で辿らず libplist の XML 経由にする)

    private static func plistToXML(_ node: UnsafeMutableRawPointer) throws -> Data {
        var xmlPtr: UnsafeMutablePointer<CChar>?
        var xmlLen: UInt32 = 0
        let rc = plist_to_xml(node, &xmlPtr, &xmlLen)
        guard rc == PLIST_ERR_SUCCESS, let xmlPtr else { throw TsukaimaIdeviceError.plistDecodeFailed }
        defer { plist_mem_free(xmlPtr) }  // plist_to_xml の出力は plist_mem_free で返す(plist.h。plist_free とは別物)
        return Data(bytes: xmlPtr, count: Int(xmlLen))
    }

    private static func plistFromXML(_ xml: Data) throws -> UnsafeMutableRawPointer {
        var node: UnsafeMutableRawPointer?
        let rc = xml.withUnsafeBytes { raw in
            plist_from_xml(raw.bindMemory(to: CChar.self).baseAddress, UInt32(raw.count), &node)
        }
        guard rc == PLIST_ERR_SUCCESS, let node else { throw TsukaimaIdeviceError.plistEncodeFailed }
        return node
    }
}
