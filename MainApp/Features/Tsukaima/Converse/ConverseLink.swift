import Foundation

/// `/ws/converse` への WebSocket(docs/converse-protocol.md 1章)。
/// TsukaimaUplink と同じ形: 内部状態は q 上で触り、コールバックは main で呼ぶ。
/// 会話はリアルタイムなので、切断中に溜めた音声は(講義録音と違って)再接続後に送らず捨てる
/// (古い発話を後から送っても意味がない)。
final class ConverseLink: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum LinkState { case idle, connecting, open, reconnecting }

    /// サーバーの会話状態(state メッセージ)
    struct AudioHeader { let id: String; let kind: String; let format: String; let bytes: Int }

    var onLinkState: ((LinkState) -> Void)?
    var onServerState: ((String) -> Void)?           // "idle" | "accepted" | "working" | "speaking" | "question"
    var onTranscript: ((String, Bool) -> Void)?       // text, final
    var onAudio: ((AudioHeader, Data) -> Void)?       // ヘッダの直後に届いたバイナリ本体とセットで
    var onReplyText: ((String) -> Void)?

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

    // MARK: 外から

    func connect() {
        q.async { [self] in
            guard state == .idle else { return }
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
        task = t
        setState(state == .idle ? .connecting : .reconnecting)
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
        guard state != .idle else { return }
        AudioDiag.logWithApp("audio link drop reason=\(reason) state=\(state) backoff=\(backoff)")
        gen += 1
        task?.cancel()
        task = nil
        pendingAudio = nil
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
        setState(.open)
        sendHello(webSocketTask)
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
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
              let type = o["type"] as? String else { return }
        switch type {
        case "state":
            if let st = o["state"] as? String { ui { self.onServerState?(st) } }
        case "transcript":
            let text = o["text"] as? String ?? ""
            let final = (o["final"] as? Bool) ?? false
            ui { self.onTranscript?(text, final) }
        case "audio":
            guard let id = o["id"] as? String else { return }
            let kind = o["kind"] as? String ?? "speech"
            let format = o["format"] as? String ?? "wav"
            let bytes = (o["bytes"] as? NSNumber)?.intValue ?? 0
            pendingAudio = AudioHeader(id: id, kind: kind, format: format, bytes: bytes)
        case "reply_text":
            let text = o["text"] as? String ?? ""
            ui { self.onReplyText?(text) }
        default:
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
