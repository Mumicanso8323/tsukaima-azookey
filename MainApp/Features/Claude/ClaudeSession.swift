import Combine
import Foundation
import UIKit

/// `/ws/claude`(docs/converse-protocol.md 2章)。hub の対話セッションをどこからでも同じに見せる経路。
/// 形は TsukaimaUplink と同じ(内部状態は q 上、コールバック/@Published は main)。
/// 再接続時は `hello since:<最後に見た seq> session:<選んでいるセッション>` を送り、抜けを埋めてもらう。
final class ClaudeSession: NSObject, ObservableObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum LinkState { case idle, connecting, open, reconnecting }

    static let shared = ClaudeSession()
    private static let selectedSessionKey = "claude.selectedSession"

    @Published private(set) var linkState = LinkState.idle
    @Published private(set) var events: [ClaudeEvent] = []
    @Published private(set) var status = ClaudeStatus()
    @Published private(set) var projects: [ClaudeProject] = []
    @Published private(set) var sessions: [ClaudeSessionInfo] = []
    /// いま見ているセッション。nil = 会話モードの常駐セッション。タブを閉じても覚えている(UserDefaults)。
    @Published private(set) var selectedSession: String? = UserDefaults.standard.string(forKey: ClaudeSession.selectedSessionKey)
    @Published var errorMessage: String?
    /// {"type":"notice"} を軽く表示するための一時メッセージ(送信を断られた、など)。
    @Published var notice: String?

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
    /// q 上で読む選択セッションの写し(@Published は main 専用の約束なので、ws のコールバックはこちらを見る)。
    private var selectedSessionID: String?

    private override init() {
        super.init()
        selectedSessionID = UserDefaults.standard.string(forKey: Self.selectedSessionKey)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: 接続

    func connect() {
        q.async { [self] in
            guard !shouldRun else { return }
            shouldRun = true
            backoff = 1
            if ClaudeConfig.isMock {
                // UI テスト: サーバーに繋がず偽サーバーの台本を流す
                setState(.open)
                ClaudeMockDriver.shared.start(self)
                return
            }
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

    /// 前面に戻ってきたとき、繋がっていなければ待たずに今すぐ繋ぎ直す(バックグラウンドで死んだ
    /// ソケットが delegate のエラーを拾えないまま、点がずっとオレンジ/灰のままになるのを防ぐ)。
    @objc private func appDidBecomeActive() {
        q.async { [self] in
            guard shouldRun, !ClaudeConfig.isMock, state != .open, state != .connecting else { return }
            gen += 1
            backoff = 1
            open()
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
        backoff = min(backoff * 2, 10)  // 指数的に間隔を空ける(1,2,4,8,10...秒)。二重に開かないよう gen で守る
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, g == self.gen, self.shouldRun else { return }
            self.open()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        backoff = 1
        setState(.open)
        var hello: [String: Any] = ["type": "hello", "since": lastSeq]
        if let sel = selectedSessionID { hello["session"] = sel }
        sendJSONRaw(webSocketTask, hello)
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard t === task else { return }
        dropped()
    }

    // MARK: アプリ → サーバー

    func send(text: String, attachmentIDs: [String] = []) {
        // スラッシュコマンドは send の text に入れても「本体への文」止まりで効かない。コマンドは keys で
        // (docs/converse-protocol.md 2章、複数セッション対応)。添付が無いときだけ振り分ける。
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachmentIDs.isEmpty, trimmed.hasPrefix("/") {
            keys(trimmed)
            return
        }
        sendJSON(["type": "send", "text": text, "attachments": attachmentIDs])
    }

    /// 画面にそのまま打ち込む(スラッシュコマンド)。チャンネルの無いセッションでも tmux が分かれば効く。
    func keys(_ text: String) {
        sendJSON(["type": "keys", "text": text])
    }

    func set(model: String? = nil, effort: String? = nil, project: String? = nil) {
        var obj: [String: Any] = ["type": "set"]
        if let model { obj["model"] = model }
        if let effort { obj["effort"] = effort }
        if let project { obj["project"] = project }
        guard obj.count > 1 else { return }
        sendJSON(obj)
    }

    /// 会話モード(声)の送り先を変える。nil で常駐セッションに戻す。
    func setConverseSession(_ sessionID: String?) {
        sendJSON(["type": "set", "converse_session": sessionID ?? NSNull()])
    }

    func interrupt() {
        sendJSON(["type": "interrupt"])
    }

    /// 見るセッションを切り替える(選択は覚えておく)。履歴は空にして、そのセッションの seq 0 から
    /// 再送してもらう(seq はセッションごとに振られるため)。
    func selectSession(_ sessionID: String?) {
        if let sessionID {
            UserDefaults.standard.set(sessionID, forKey: Self.selectedSessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedSessionKey)
        }
        ui {
            self.selectedSession = sessionID
            self.events.removeAll()
        }
        q.async { [self] in
            selectedSessionID = sessionID
            lastSeq = 0
        }
        sendJSON(["type": "select", "session": sessionID ?? NSNull(), "since": 0])
    }

    private func sendJSON(_ obj: [String: Any]) {
        if ClaudeConfig.isMock {
            ClaudeMockDriver.shared.received(obj, session: self)
            return
        }
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
        case "notice":
            // 送信を断られた(チャンネルが無い/tmux が見つからない)ときなどの一言(docs/converse-protocol.md 2章)。
            let text = o["text"] as? String ?? ""
            if !text.isEmpty { ui { self.notice = text } }
        case "ping":
            break  // Cloudflare Tunnel の無通信切断を防ぐための生存確認。何もしなくてよい
        default:
            break
        }
    }

    // MARK: HTTP(添付・プロジェクト一覧・セッション一覧・状態)

    func refreshSessions() async {
        if ClaudeConfig.isMock {
            let list = ClaudeMockDriver.shared.sessions()
            ui { self.sessions = list }
            return
        }
        do {
            let list = try await getJSONArray(ClaudeConfig.sessionsURL)
            let parsed = list.compactMap(ClaudeSessionInfo.parse)
            ui { self.sessions = parsed }
        } catch {
            // セッション一覧が取れなくても常駐セッションの閲覧はできるので致命的ではない
        }
    }

    func refreshProjects() async {
        if ClaudeConfig.isMock {
            ui { self.projects = [ClaudeProject(name: "モック", cwd: "/tmp/mock")] }
            return
        }
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
        if ClaudeConfig.isMock { return }
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
        if ClaudeConfig.isMock { return "mock-\(UUID().uuidString.prefix(8))" }
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

    // MARK: UI テスト(ClaudeMockDriver)

    /// 偽サーバーからの 1 行を、本物の受信と同じ経路で処理する。
    func mockIngest(_ text: String) {
        q.async { [self] in handleText(text) }
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
