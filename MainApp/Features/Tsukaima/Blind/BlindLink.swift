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

    var onLinkState: ((LinkState) -> Void)?
    var onBeep: ((BlindBeep) -> Void)?
    var onState: ((ServerState) -> Void)?

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
    private var ready = false
    private var sending = false
    private var queue = BlindKeyQueue()

    // MARK: 外から

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
        if announce { ui { self.onBeep?(.error) } }

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
        pump()  // ready が先に処理されていたら、ここで溜めたキーを流す
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
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    if expectedGeneration == self.generation {
                        self.receive(webSocket, expectedGeneration)
                    }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            pump()
        case "beep":
            guard let name = object["name"] as? String, let beep = Self.beep(named: name) else { return }
            ui { self.onBeep?(beep) }
        case "state":
            guard let blindOn = object["blind_on"] as? Bool,
                  let mode = object["mode"] as? String else { return }
            let serverState = ServerState(blindOn: blindOn, mode: mode)
            ui { self.onState?(serverState) }
        default:
            break
        }
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
