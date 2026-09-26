import Foundation

/// WebSocket 送信。切断中の音声はメモリにだけ溜め(最大30分・古い順に捨てる)、
/// 再接続時は lecture=<id> を付けて同じ講義に追記する。
/// 内部状態はすべて q 上で触る。コールバックは main で呼ぶ。
final class TsukaimaUplink: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum State { case idle, connecting, open, reconnecting }
    struct Start { let lecture: Int; let course: String?; let end: Date? }

    var onState: ((State, Int) -> Void)?  // 状態, 送信待ち(秒)
    var onStart: ((Start) -> Void)?
    var onText: ((String) -> Void)?
    var onDone: (() -> Void)?

    private let q = DispatchQueue(label: "uplink")
    private lazy var session: URLSession = {
        let oq = OperationQueue()
        oq.underlyingQueue = q
        oq.maxConcurrentOperationCount = 1
        return URLSession(configuration: .default, delegate: self, delegateQueue: oq)
    }()
    private var task: URLSessionWebSocketTask?
    private var gen = 0          // 古い接続からのコールバックを捨てるための世代番号
    private var state = State.idle
    private var queue: [Data] = []
    private var sending = false
    private var finishing = false
    private var stopSent = false
    private var course: String?
    private var lecture: Int?
    private var backoff = 1.0

    // MARK: 外から

    func begin(course: String?) {
        q.async { [self] in
            self.course = course
            lecture = nil
            queue = []
            finishing = false
            backoff = 1
            state = .idle
            connect()
        }
    }

    func push(_ chunk: Data) {
        q.async { [self] in
            guard state != .idle else { return }
            queue.append(chunk)
            if queue.count > TsukaimaConfig.maxBufferedChunks {
                queue.removeFirst(queue.count - TsukaimaConfig.maxBufferedChunks)
            }
            report()
            pump()
        }
    }

    /// 溜まった音声を送り切ってから stop を送り、done を待って閉じる
    func finish() {
        q.async { [self] in
            finishing = true
            pump()
        }
    }

    /// 未送信分を捨てて即終了
    func abort() {
        q.async { [self] in close() }
    }

    // MARK: 接続

    private func connect() {
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        sending = false
        stopSent = false
        var c = URLComponents(url: TsukaimaConfig.wsURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let course { items.append(URLQueryItem(name: "course", value: course)) }
        if let lecture { items.append(URLQueryItem(name: "lecture", value: String(lecture))) }
        c.queryItems = items.isEmpty ? nil : items
        let t = session.webSocketTask(with: c.url!)
        task = t
        setState(state == .idle ? .connecting : .reconnecting)
        t.resume()
        receive(t, gen)
    }

    private func dropped() {
        guard state != .idle else { return }
        gen += 1
        task?.cancel()
        task = nil
        sending = false
        setState(.reconnecting)
        let g = gen, delay = backoff
        backoff = min(backoff * 2, 10)
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, g == self.gen, self.state != .idle else { return }
            self.connect()
        }
    }

    private func close() {
        gen += 1
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        queue = []
        sending = false
        finishing = false
        setState(.idle)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        backoff = 1
        setState(.open)
        pump()
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard t === task else { return }
        dropped()
    }

    // MARK: 送受信

    private func pump() {
        guard state == .open, !sending, let t = task else { return }
        let g = gen
        if let head = queue.first {
            sending = true
            t.send(.data(head)) { [weak self] err in
                self?.q.async {
                    guard let self, g == self.gen else { return }
                    self.sending = false
                    if err != nil { self.dropped(); return }
                    if self.queue.first == head { self.queue.removeFirst() }
                    self.report()
                    self.pump()
                }
            }
        } else if finishing && !stopSent {
            stopSent = true
            t.send(.string(#"{"type":"stop"}"#)) { _ in }
            // done が来なくても 20秒で諦めて閉じる
            q.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, g == self.gen, self.finishing else { return }
                self.close()
                self.ui { self.onDone?() }
            }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ g: Int) {
        t.receive { [weak self] r in
            self?.q.async {
                guard let self, g == self.gen else { return }
                switch r {
                case .failure:
                    self.dropped()
                case .success(let m):
                    if case .string(let s) = m { self.handle(s) }
                    if g == self.gen { self.receive(t, g) }
                }
            }
        }
    }

    private func handle(_ s: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return }
        switch o["type"] as? String {
        case "start":
            if let id = (o["lecture"] as? NSNumber)?.intValue { lecture = id }
            let st = Start(lecture: lecture ?? 0,
                           course: o["course"] as? String,
                           end: (o["end"] as? String).flatMap(Self.parseDate))
            ui { self.onStart?(st) }
        case "text":
            if let text = o["text"] as? String, !text.isEmpty { ui { self.onText?(text) } }
        case "done":
            close()
            ui { self.onDone?() }
        default:
            break
        }
    }

    // MARK: 補助

    private func setState(_ s: State) {
        state = s
        report()
    }

    private func report() {
        let s = state, n = queue.count
        ui { self.onState?(s, n) }
    }

    private func ui(_ f: @escaping () -> Void) {
        DispatchQueue.main.async(execute: f)
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let d = iso.date(from: s) { return d }
        // タイムゾーン無しは端末のローカル時刻とみなす
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
