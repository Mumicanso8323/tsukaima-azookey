import Combine
import Foundation

/// `/ws/claude`(docs/converse-protocol.md 2章)。常駐 Claude Code セッションをどこからでも同じに見せる経路。
/// 形は TsukaimaUplink と同じ(内部状態は q 上、コールバック/@Published は main)。
/// 再接続時は `hello since:<最後に見た seq>` を送り、抜けを埋めてもらう。
final class ClaudeSession: NSObject, ObservableObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum LinkState { case idle, connecting, open, reconnecting }

    static let shared = ClaudeSession()

    @Published private(set) var linkState = LinkState.idle
    @Published private(set) var events: [ClaudeEvent] = []
    @Published private(set) var status = ClaudeStatus()
    @Published private(set) var projects: [ClaudeProject] = []
    @Published var errorMessage: String?

    private let q = DispatchQueue(label: "claude-session")
    private lazy var urlSession: URLSession = {
        let oq = OperationQueue()
        oq.underlyingQueue = q
        oq.maxConcurrentOperationCount = 1
        return URLSession(configuration: .default, delegate: self, delegateQueue: oq)
    }()
    private var task: URLSessionWebSocketTask?
    private var gen = 0
    private var state = LinkState.idle
    private var backoff = 1.0
    private var lastSeq = 0
    private var shouldRun = false

    private override init() {}

    // MARK: 接続

    func connect() {
        q.async { [self] in
            guard !shouldRun else { return }
            shouldRun = true
            backoff = 1
            open()
        }
    }

    func disconnect() {
        q.async { [self] in
            shouldRun = false
            gen += 1
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
            setState(.idle)
        }
    }

    private func open() {
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        let t = urlSession.webSocketTask(with: TsukaimaEndpoint.request(ClaudeConfig.wsURL))
        task = t
        setState(state == .idle ? .connecting : .reconnecting)
        t.resume()
        receive(t, gen)
    }

    private func dropped() {
        guard shouldRun else { return }
        gen += 1
        task?.cancel()
        task = nil
        setState(.reconnecting)
        let g = gen, delay = backoff
        backoff = min(backoff * 2, 10)
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, g == self.gen, self.shouldRun else { return }
            self.open()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        backoff = 1
        setState(.open)
        sendJSONRaw(webSocketTask, ["type": "hello", "since": lastSeq])
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard t === task else { return }
        dropped()
    }

    // MARK: アプリ → サーバー

    func send(text: String, attachmentIDs: [String] = []) {
        sendJSON(["type": "send", "text": text, "attachments": attachmentIDs])
    }

    func set(model: String? = nil, effort: String? = nil, project: String? = nil) {
        var obj: [String: Any] = ["type": "set"]
        if let model { obj["model"] = model }
        if let effort { obj["effort"] = effort }
        if let project { obj["project"] = project }
        guard obj.count > 1 else { return }
        sendJSON(obj)
    }

    func interrupt() {
        sendJSON(["type": "interrupt"])
    }

    private func sendJSON(_ obj: [String: Any]) {
        q.async { [self] in
            guard state == .open, let t = task else { return }
            sendJSONRaw(t, obj)
        }
    }

    private func sendJSONRaw(_ t: URLSessionWebSocketTask, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        t.send(.string(str)) { _ in }
    }

    // MARK: サーバー → アプリ

    private func receive(_ t: URLSessionWebSocketTask, _ g: Int) {
        t.receive { [weak self] r in
            self?.q.async {
                guard let self, g == self.gen else { return }
                switch r {
                case .failure:
                    self.dropped()
                case .success(let m):
                    if case .string(let s) = m { self.handleText(s) }
                    if g == self.gen { self.receive(t, g) }
                }
            }
        }
    }

    private func handleText(_ s: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
              let type = o["type"] as? String else { return }
        switch type {
        case "event":
            guard let ev = ClaudeEvent.parse(o) else { return }
            ui {
                self.lastSeq = max(self.lastSeq, ev.seq)
                self.events.append(ev)
                if self.events.count > 4000 { self.events.removeFirst(self.events.count - 4000) }
            }
        case "status":
            let st = ClaudeStatus.parse(o)
            ui { self.status = st }
        default:
            break
        }
    }

    // MARK: HTTP(添付・プロジェクト一覧・状態)

    func refreshProjects() async {
        do {
            let list = try await getJSONArray(ClaudeConfig.projectsURL)
            let parsed = list.compactMap { o -> ClaudeProject? in
                guard let name = o["name"] as? String, let cwd = o["cwd"] as? String else { return nil }
                return ClaudeProject(name: name, cwd: cwd)
            }
            ui { self.projects = parsed }
        } catch {
            ui { self.errorMessage = "プロジェクト一覧を取得できませんでした" }
        }
    }

    func refreshState() async {
        do {
            let obj = try await getJSONObject(ClaudeConfig.stateURL)
            let st = ClaudeStatus.parse(obj)
            ui { self.status = st }
        } catch {
            // 起動直後などは無視してよい(WS の status で追いつく)
        }
    }

    /// 写真・ファイルを `/api/claude/upload` に上げて id を受け取る(送信時に attachments へ入れる)
    func upload(data: Data, filename: String, mime: String) async throws -> String {
        let obj = try await TsukaimaNet.postMultipart(ClaudeConfig.uploadURL, fields: [:], fileField: "file",
                                                       filename: filename, mime: mime, data: data)
        guard let id = obj["id"] as? String, !id.isEmpty else {
            throw NSError(domain: "claude", code: 1, userInfo: [NSLocalizedDescriptionKey: "アップロードの応答が読めません"])
        }
        return id
    }

    private func getJSONObject(_ url: URL) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: TsukaimaEndpoint.request(url))
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TsukaimaNet.HTTPError(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "claude", code: 2)
        }
        return obj
    }

    private func getJSONArray(_ url: URL) async throws -> [[String: Any]] {
        let (data, resp) = try await URLSession.shared.data(for: TsukaimaEndpoint.request(url))
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TsukaimaNet.HTTPError(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "claude", code: 2)
        }
        return arr
    }

    // MARK: 補助

    private func setState(_ s: LinkState) {
        state = s
        ui { self.linkState = s }
    }

    private func ui(_ f: @escaping () -> Void) {
        DispatchQueue.main.async(execute: f)
    }
}
