import Foundation

/// `/ws/converse` への WebSocket(docs/converse-protocol.md 1章)。
/// TsukaimaUplink と同じ形: 内部状態は q 上で触り、コールバックは main で呼ぶ。
/// 会話はリアルタイムなので、切断中に溜めた音声は(講義録音と違って)再接続後に送らず捨てる
/// (古い発話を後から送っても意味がない)。
final class ConverseLink: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// authFailed: サーバーが 4403(認証が通らない)で閉じた。張り直しても無駄なので止まる(A3・S12)
    enum LinkState { case idle, connecting, open, reconnecting, authFailed }

    /// サーバーの会話状態(state メッセージ)
    struct AudioHeader: Equatable { let id: String; let kind: String; let format: String; let bytes: Int }

    var onLinkState: ((LinkState) -> Void)?
    var onServerState: ((String) -> Void)?           // "idle" | "accepted" | "working" | "speaking" | "question"
    var onTranscript: ((String, Bool) -> Void)?       // text, final
    var onAudio: ((AudioHeader, Data) -> Void)?       // ヘッダの直後に届いたバイナリ本体とセットで
    var onReplyText: ((String) -> Void)?
    /// 声の合成が全滅(sent=0)か途中で止まった(sent=送れた本数)。text は返事の全文(A2)
    var onSpeechFailed: ((String, Int) -> Void)?
    /// 端末で読み上げる知らせ(code, say)(A2)
    var onNotice: ((String, String) -> Void)?

    private let q = DispatchQueue(label: "converse-link")
    private lazy var session: URLSession = {
        let oq = OperationQueue()
        oq.underlyingQueue = q
        oq.maxConcurrentOperationCount = 1
        return URLSession(configuration: .default, delegate: self, delegateQueue: oq)
    }()
    private var task: URLSessionWebSocketTask?
    private var gen = 0
    private var state = LinkState.idle
    private var backoff = 1.0
    private var pendingAudio: AudioHeader?
    /// 受信ウォッチドッグ(A1): ping も音声も 25 秒届かなければ半開きとみなして張り直す
    private var rxWatch = ConverseRxWatchdog()
    private var rxTimer: DispatchSourceTimer?
    /// 4403 で閉じられた印(直後の didComplete で張り直さない)
    private var authFailed = false
    /// 接続を始めた時刻(connectTimeout 秒で開かなければ張り直す。SYN が返らない圏外・トンネル内向け)
    private var connectStarted: Double?
    static let connectTimeout = 15.0

    // MARK: 外から

    func connect() {
        q.async { [self] in
            guard state == .idle || state == .authFailed else { return }
            authFailed = false
            backoff = 1
            open()
        }
    }

    func disconnect(sendStop: Bool) {
        q.async { [self] in
            if sendStop, state == .open, let t = task {
                t.send(.string(#"{"type":"stop"}"#)) { _ in }
            }
            gen += 1
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
            pendingAudio = nil
            stopRxWatch()
            setState(.idle)
        }
    }

    /// マイクの PCM チャンク(バイナリフレーム)。未接続中は捨てる(会話はリアルタイムなので古い音声を後で送らない)。
    func pushAudio(_ chunk: Data) {
        q.async { [self] in
            guard state == .open, let t = task else { return }
            t.send(.data(chunk)) { [weak self] err in
                guard err != nil else { return }
                self?.q.async { self?.dropped() }
            }
        }
    }

    func sendPlayed(id: String) {
        sendJSON(["type": "played", "id": id])
    }

    private func sendJSON(_ obj: [String: Any]) {
        q.async { [self] in
            guard state == .open, let t = task,
                  let data = try? JSONSerialization.data(withJSONObject: obj),
                  let str = String(data: data, encoding: .utf8) else { return }
            t.send(.string(str)) { _ in }
        }
    }

    // MARK: 接続

    private func open() {
        AudioDiag.logWithApp("audio link open state=\(state) backoff=\(backoff)")
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        pendingAudio = nil
        let t = session.webSocketTask(with: TsukaimaEndpoint.request(ConverseConfig.wsURL))
        // 既定の 1 MiB を超えるメッセージで "message too long" になり接続が落ちる。キーボード橋(8 MiB)と揃える。
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        setState(state == .idle || state == .authFailed ? .connecting : .reconnecting)
        connectStarted = ProcessInfo.processInfo.systemUptime
        startWatchTimer()
        t.resume()
        receive(t, gen)
    }

    private func sendHello(_ t: URLSessionWebSocketTask) {
        let hello: [String: Any] = ["type": "hello", "device": ConverseDeviceID.current(), "resume": true]
        guard let data = try? JSONSerialization.data(withJSONObject: hello),
              let str = String(data: data, encoding: .utf8) else { return }
        t.send(.string(str)) { _ in }
    }

    private func dropped(_ reason: String = "?") {
        guard state != .idle, state != .authFailed else { return }
        AudioDiag.logWithApp("audio link drop reason=\(reason) state=\(state) backoff=\(backoff)")
        gen += 1
        task?.cancel()
        task = nil
        pendingAudio = nil
        rxWatch.reset()
        connectStarted = nil
        setState(.reconnecting)
        let g = gen, delay = backoff
        backoff = min(backoff * 2, 10)
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, g == self.gen, self.state != .idle else { return }
            self.open()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        backoff = 1
        connectStarted = nil
        setState(.open)
        sendHello(webSocketTask)
        rxWatch.touch(now: ProcessInfo.processInfo.systemUptime)
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard t === task else { return }
        let e = error as NSError?
        dropped("complete err=\(e.map { "\($0.domain)#\($0.code)" } ?? "nil")")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        AudioDiag.logWithApp("audio link close code=\(closeCode.rawValue) reasonBytes=\(reason?.count ?? 0)")
        // 4403 = 認証が通らない(合鍵・Access トークン失効)。張り直しても同じなので止めて、端末で知らせる(A3)
        if closeCode.rawValue == 4403 {
            authFailed = true
            gen += 1
            task = nil
            pendingAudio = nil
            stopRxWatch()
            setState(.authFailed)
        }
    }

    // MARK: 受信ウォッチドッグ(A1)+接続の時間切れ

    /// 5 秒ごとに見る: 開いていれば受信の途絶(25 秒)、開く途中なら接続の時間切れ(15 秒)。
    private func startWatchTimer() {
        guard rxTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch self.state {
            case .open:
                if self.rxWatch.isStale(now: now) {
                    self.dropped("rx timeout \(Int(now - (self.rxWatch.lastReceived ?? now)))s")
                }
            case .connecting, .reconnecting:
                if let t0 = self.connectStarted, now - t0 > Self.connectTimeout {
                    self.dropped("connect timeout \(Int(now - t0))s")
                }
            case .idle, .authFailed:
                break
            }
        }
        t.resume()
        rxTimer = t
    }

    private func stopRxWatch() {
        rxTimer?.cancel()
        rxTimer = nil
        rxWatch.reset()
        connectStarted = nil
    }

    // MARK: 送受信

    private func receive(_ t: URLSessionWebSocketTask, _ g: Int) {
        t.receive { [weak self] r in
            self?.q.async {
                guard let self, g == self.gen else { return }
                switch r {
                case .failure(let error):
                    let e = error as NSError
                    self.dropped("receive err=\(e.domain)#\(e.code)")
                case .success(let m):
                    self.rxWatch.touch(now: ProcessInfo.processInfo.systemUptime)
                    switch m {
                    case .string(let s): self.handleText(s)
                    case .data(let d): self.handleBinary(d)
                    @unknown default: break
                    }
                    if g == self.gen { self.receive(t, g) }
                }
            }
        }
    }

    private func handleText(_ s: String) {
        guard let m = ConverseServerMessage.parse(s) else { return }
        switch m {
        case .state(let st):
            ui { self.onServerState?(st) }
        case .transcript(let text, let final):
            ui { self.onTranscript?(text, final) }
        case .audio(let header):
            pendingAudio = header
        case .replyText(let text):
            ui { self.onReplyText?(text) }
        case .ping(let st):
            // ping の state がアプリの表示と違えばサーバーに合わせる(受信の記録は receive 側で済み)
            if let st { ui { self.onServerState?(st) } }
        case .speechFailed(let text, let sent):
            ui { self.onSpeechFailed?(text, sent) }
        case .notice(let code, let say):
            ui { self.onNotice?(code, say) }
        case .held, .unknown:
            break
        }
    }

    private func handleBinary(_ d: Data) {
        guard let header = pendingAudio else { return }
        pendingAudio = nil
        ui { self.onAudio?(header, d) }
    }

    // MARK: 補助

    private func setState(_ s: LinkState) {
        state = s
        ui { self.onLinkState?(s) }
    }

    private func ui(_ f: @escaping () -> Void) {
        DispatchQueue.main.async(execute: f)
    }
}
