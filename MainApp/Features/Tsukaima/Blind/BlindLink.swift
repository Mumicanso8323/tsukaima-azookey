import Foundation

/// `/ws/blind` のキー転送。内部状態は `q`、画面への通知は main queue に限定する。
final class BlindLink: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum LinkState: Equatable {
        case idle
        case connecting
        case open
        case reconnecting
    }

    struct ServerState: Equatable, Sendable {
        let blindOn: Bool
        let mode: String
    }

    /// proto 2 の `path`(返事の経路の状態)。
    struct PathState: Equatable, Sendable {
        let ok: Bool
        let busy: Bool
        let audioOwner: String
        let name: String?
    }

    var onLinkState: ((LinkState) -> Void)?
    var onBeep: ((BlindBeep) -> Void)?
    var onState: ((ServerState) -> Void)?
    var onConfigOK: ((Int) -> Void)?
    /// 返事の経路(サーバーの /ws/converse の聞き手)の有無。ready の直後と、増減のたびに届く。
    var onListener: ((Bool) -> Void)?
    /// つながっていたのが落ちたとき(落ちた最初の 1 回)。鳴らす・震えるかは host が決める(背面・Claude タブ前面では告知しない)。
    var onDisconnected: (() -> Void)?
    /// ready を受けたとき。proto が nil なら古いサーバー(proto 1)。
    var onReady: ((Int?, String?) -> Void)?
    var onReply: ((BlindReply) -> Void)?
    var onOutput: ((BlindOutputMode) -> Void)?
    var onPath: ((PathState) -> Void)?
    var onHeld: ((Int) -> Void)?
    /// audio ヘッダと、直後のバイナリ 1 本の組。
    var onAudio: ((BlindAudioHeader, Data) -> Void)?

    private let q = DispatchQueue(label: "blind-link")
    private lazy var session: URLSession = {
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = q
        operationQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: .default, delegate: self, delegateQueue: operationQueue)
    }()
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var state = LinkState.idle
    private var backoff: TimeInterval = 1
    private var ready = false {
        didSet {
            if !ready {
                configSent = false
                helloSent = false
                proto = nil
                pendingAudio = nil
            }
        }
    }
    private var configSent = false
    private var helloSent = false
    /// ready で知らされた proto(proto 2 のときだけ hello を送る)。つなぎ直すたびに nil に戻る。
    private var proto: Int?
    private var hello: BlindHelloState?
    private var pendingAudio: BlindAudioHeader?
    private var testOutbox: ((String) -> Void)?
    private var probeNonce = 0
    private var pongNonce = 0
    private(set) var foregroundChecks = 0
    private var bindings: BlindBindings
    private var sending = false
    private var queue = BlindKeyQueue()

    init(store: BlindBindingsStore = BlindBindingsStore()) {
        bindings = store.load()
        super.init()
    }

    // MARK: 外から

    /// 合図のキーを差し替える。つながっていれば、すぐ config を送り直す(空でも送り、前の config を消す)。
    func setBindings(_ newBindings: BlindBindings) {
        q.async { [self] in
            bindings = newBindings
            guard state == .open, ready else { return }
            configSent = true
            sendConfig(allowEmpty: true)
        }
    }

    /// hello で宣言する内容。つなぐ前と、宣言の元が変わるたびに host が更新する(送るのは ready の直後)。
    func setHello(_ newHello: BlindHelloState) {
        q.async { [self] in hello = newHello }
    }

    func sendOutputSet(_ mode: BlindOutputMode) {
        sendProto2(["type": "output_set", "mode": mode.rawValue])
    }

    func sendRoute(_ route: BlindRoute) {
        sendProto2(["type": "route", "route": route.rawValue])
    }

    func sendCaps(audio: Bool) {
        sendProto2(["type": "caps", "audio": audio])
    }

    func sendRead() {
        sendProto2(["type": "read"])
    }

    func sendPlayed(id: String) {
        sendProto2(["type": "played", "id": id])
    }

    /// テスト(UI テストの mock)用: サーバーから届いたことにして handle に流す。
    func ingestForTesting(_ text: String) {
        q.async { [self] in handle(text) }
    }

    /// テスト用: 届いた(ヘッダの次の)バイナリとして handleBinary に流す。
    func ingestBinaryForTesting(_ data: Data) {
        q.async { [self] in handleBinary(data) }
    }

    /// テスト用: 送るはずの文字列をここに溜める(WebSocket を使わない)。設定すると、つながった状態として扱う。
    func useTestOutbox(_ outbox: @escaping (String) -> Void) {
        q.sync {
            testOutbox = outbox
            state = .open
        }
    }

    /// テスト用: キューの処理が終わるまで待つ。
    func drainForTesting() {
        q.sync {}
    }

    /// 前面に戻ったときの生死の確認(DEC-14: 背面・ロック中にソケットが黙って死んでいても、復帰で気づく)。
    /// つながっていなければ待たずにすぐつなぎ直す。つながっているように見えれば、protocol の ping で生死を確かめる。
    func resumeFromBackground() {
        q.async { [self] in
            foregroundChecks += 1
            switch Self.foregroundAction(state: state) {
            case .none:
                break
            case .reconnectNow:
                backoff = 1
                generation += 1
                task?.cancel(with: .goingAway, reason: nil)
                task = nil
                ready = false
                sending = false
                open()
            case .probe:
                probeAlive()
            }
        }
    }

    enum ForegroundAction: Equatable {
        case none
        case reconnectNow
        case probe
    }

    /// 復帰時にすることの規則(純粋)。idle(つなぐ気がない)は何もしない。
    static func foregroundAction(state: LinkState) -> ForegroundAction {
        switch state {
        case .idle: return .none
        case .connecting, .reconnecting: return .reconnectNow
        case .open: return .probe
        }
    }

    private func probeAlive() {
        guard let webSocket = task else { return }
        probeNonce += 1
        let nonce = probeNonce
        let expectedGeneration = generation
        webSocket.sendPing { [weak self] error in
            self?.q.async {
                guard let self, expectedGeneration == self.generation else { return }
                if error == nil { self.pongNonce = nonce } else { self.deadOnResume() }
            }
        }
        q.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, expectedGeneration == self.generation, self.pongNonce < nonce else { return }
            self.deadOnResume()  // pong が返らない: 黙って死んでいる
        }
    }

    private func deadOnResume() {
        backoff = 1
        dropped()
    }

    func connect() {
        q.async { [self] in
            guard state == .idle else { return }
            backoff = 1
            open()
        }
    }

    func disconnect() {
        q.async { [self] in
            generation += 1
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
            ready = false
            sending = false
            queue = BlindKeyQueue()  // 画面を出入りしたあとに、古いキーを送り直さない
            setState(.idle)
        }
    }

    func push(_ event: BlindKeyEvent) {
        q.async { [self] in
            queue.append(event, now: ProcessInfo.processInfo.systemUptime)
            pump()
        }
    }

    /// テストと受信処理で同じ unknown-name の無視を使う。
    static func beep(named name: String) -> BlindBeep? {
        BlindBeep(rawValue: name)
    }

    /// {"type":"listener","on":Bool} だけを読む。ほかの type・欠けた/型違いの on は nil(無視)。
    static func parseListener(_ text: String) -> Bool? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["type"] as? String == "listener" else { return nil }
        return object["on"] as? Bool
    }

    // MARK: 接続

    private func open() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
        sending = false
        setState(state == .idle ? .connecting : .reconnecting)

        guard let request = handshakeRequest() else {
            dropped()
            return
        }
        let webSocket = session.webSocketTask(with: request)
        // 既定の 1 MiB では、約 20 秒を超える wav で receive が失敗し、再接続→再送のループになる。
        webSocket.maximumMessageSize = BlindAudioFrame.maxBytes + 64 * 1024
        task = webSocket
        webSocket.resume()
        receive(webSocket, generation)
    }

    private func handshakeRequest() -> URLRequest? {
        guard var components = URLComponents(url: TsukaimaEndpoint.webSocketURL("/ws/blind"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "session", value: "default")]
        guard let url = components.url else { return nil }

        var request = TsukaimaEndpoint.request(url)
        request.httpMethod = "GET"
        // 公開ホストでは Bearer に加え、空本文の GET /ws/blind を端末鍵で署名する。
        if TsukaimaDeviceAuth.isPaired {
            guard let headers = try? TsukaimaDeviceAuth.signatureHeaders(method: "GET", path: "/ws/blind", body: Data()) else {
                return nil
            }
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    private func dropped() {
        guard state != .idle else { return }
        // 切断を知らせる error 音は、落ちた最初の1回だけ(再接続の失敗では鳴らさない)。
        let announce = state != .reconnecting
        generation += 1
        task?.cancel()
        task = nil
        ready = false
        sending = false
        setState(.reconnecting)
        if announce { ui { self.onDisconnected?() } }

        let expectedGeneration = generation
        let delay = backoff
        backoff = min(backoff * 2, 10)
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, expectedGeneration == self.generation, self.state != .idle else { return }
            self.open()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        backoff = 1
        setState(.open)
        schedulePing(for: generation)
        flushHandshake()  // ready が先に処理されていたら、ここで config → 溜めたキーの順に流す
    }

    func urlSession(_ session: URLSession, task completedTask: URLSessionTask, didCompleteWithError error: Error?) {
        guard completedTask === task else { return }
        dropped()
    }

    // MARK: 送受信

    private func receive(_ webSocket: URLSessionWebSocketTask, _ expectedGeneration: Int) {
        webSocket.receive { [weak self] result in
            self?.q.async {
                guard let self, expectedGeneration == self.generation else { return }
                switch result {
                case .failure:
                    self.dropped()
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        self.handleBinary(data)
                    @unknown default:
                        break
                    }
                    if expectedGeneration == self.generation {
                        self.receive(webSocket, expectedGeneration)
                    }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = BlindServerMessage.parse(text) else { return }
        switch message {
        case .ready(let serverProto, let epoch):
            proto = serverProto
            ready = true
            ui { self.onReady?(serverProto, epoch) }
            flushHandshake()
        case .configOK(let count):
            ui { self.onConfigOK?(count) }
        case .beep(let beep):
            ui { self.onBeep?(beep) }
        case .state(let blindOn, let mode):
            let serverState = ServerState(blindOn: blindOn, mode: mode)
            ui { self.onState?(serverState) }
        case .listener(let on):
            ui { self.onListener?(on) }
        case .reply(let reply):
            ui { self.onReply?(reply) }
        case .output(let mode):
            ui { self.onOutput?(mode) }
        case .path(let ok, let busy, let audioOwner, let name):
            let path = PathState(ok: ok, busy: busy, audioOwner: audioOwner, name: name)
            ui { self.onPath?(path) }
        case .held(let count):
            ui { self.onHeld?(count) }
        case .audio(let header):
            // 前のヘッダのバイナリが来ないまま次のヘッダが来た: 置き換わる id も played を返して、サーバーを待たせない
            if let replaced = pendingAudio { sendProto2(["type": "played", "id": replaced.id]) }
            pendingAudio = header  // 直後のバイナリ 1 本と組にする
        }
    }

    private func handleBinary(_ data: Data) {
        guard let header = pendingAudio else { return }  // ヘッダの無いバイナリは無視
        pendingAudio = nil
        // 大きさがヘッダと合わない・上限超え・変な id: 渡さず、played だけ返す
        guard BlindAudioFrame.isValid(header: header, data: data) else {
            sendProto2(["type": "played", "id": header.id])
            return
        }
        ui { self.onAudio?(header, data) }
    }

    /// ready と open がそろった時に 1 回だけ config を送り(保存済みなら)、そのあとキーを流す。
    private func flushHandshake() {
        guard state == .open, ready, task != nil || testOutbox != nil else { return }
        if (proto ?? 0) >= 2, !helloSent, let text = hello?.jsonText() {
            helloSent = true
            sendText(text)  // config / keys より先に宣言する
        }
        if !configSent {
            configSent = true
            sendConfig(allowEmpty: false)
        }
        pump()
    }

    private func sendText(_ text: String) {
        if let testOutbox {
            testOutbox(text)
            return
        }
        guard let webSocket = task else { return }
        let expectedGeneration = generation
        webSocket.send(.string(text)) { [weak self] error in
            self?.q.async {
                guard let self, expectedGeneration == self.generation else { return }
                if error != nil { self.dropped() }
            }
        }
    }

    /// proto 2 のときだけ送る。そうでなければ捨てる(つなぎ直しの hello が宣言し直す)。
    private func sendProto2(_ object: [String: Any]) {
        q.async { [self] in
            guard state == .open, ready, (proto ?? 0) >= 2, let text = BlindJSON.encode(object) else { return }
            sendText(text)
        }
    }

    private func sendConfig(allowEmpty: Bool) {
        guard allowEmpty || !bindings.isEmpty, let text = bindings.configMessageText() else { return }
        sendText(text)
    }

    private func pump() {
        guard state == .open, ready, !sending, let webSocket = task else { return }
        let events = queue.firstBatch(now: ProcessInfo.processInfo.systemUptime)
        guard !events.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(KeysMessage(events: events)),
              let text = String(data: data, encoding: .utf8) else { return }

        let expectedGeneration = generation
        sending = true
        webSocket.send(.string(text)) { [weak self] error in
            self?.q.async {
                guard let self, expectedGeneration == self.generation else { return }
                self.sending = false
                if error != nil {
                    self.dropped()
                    return
                }
                // 送信中に 60 秒を超えたキーが掃除されても、新しいキーを誤って落とさない。
                let currentHead = self.queue.firstBatch(now: ProcessInfo.processInfo.systemUptime)
                if currentHead.starts(with: events) {
                    self.queue.removeFirst(events.count)
                }
                self.pump()
            }
        }
    }

    private func schedulePing(for expectedGeneration: Int) {
        q.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, expectedGeneration == self.generation, self.state == .open,
                  let webSocket = self.task else { return }
            webSocket.send(.string(#"{"type":"ping"}"#)) { [weak self] error in
                self?.q.async {
                    guard let self, expectedGeneration == self.generation else { return }
                    if error != nil {
                        self.dropped()
                    } else {
                        self.schedulePing(for: expectedGeneration)
                    }
                }
            }
        }
    }

    private func setState(_ newState: LinkState) {
        state = newState
        ui { self.onLinkState?(newState) }
    }

    private func ui(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    private struct KeysMessage: Encodable {
        let type = "keys"
        let events: [BlindKeyEvent]
    }
}
