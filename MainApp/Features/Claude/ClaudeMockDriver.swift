import Combine
import Foundation
import Darwin
import UIKit

/// UI テスト用の偽サーバー(起動引数 `--claude-mock`、ClaudeConfig.isMock)。本番では一切動かない。
/// サーバーが送る JSON 文字列をそのまま ClaudeSession.handleText と同じ経路に流すので、解析も含めて試せる。
///   - `--claude-mock`: 固定の履歴(本文・Markdown・連続したツール呼び出し)だけ。
///   - `--claude-mock-stream`: 履歴のあと、0.3 秒ごとにイベントを流し続ける(thinking・ツール・本文・busy の切替)。
///     打鍵中・ポーリング中に画面が更新され続ける状況を作る。
/// アプリ → サーバーの送信(send/interrupt)も受けて、本物と同じように user イベントや status を返す。
final class ClaudeMockDriver: @unchecked Sendable {
    static let shared = ClaudeMockDriver()

    private let q = DispatchQueue(label: "claude-mock")
    private var seq = 0
    private var busy = false
    private var started = false
    private var sessionPolls = 0

    func start(_ session: ClaudeSession) {
        q.async { [self] in
            guard !started else { return }
            started = true
            session.mockIngest(status())
            for line in history() { session.mockIngest(line) }
            if ClaudeConfig.isMockStreaming { stream(session, tick: 0) }
        }
    }

    /// アプリが送った JSON(send/keys/interrupt/select/set)への応答。
    func received(_ obj: [String: Any], session: ClaudeSession) {
        q.async { [self] in
            switch obj["type"] as? String {
            case "send":
                session.mockIngest(event("user", ["text": obj["text"] as? String ?? "", "source": "human"]))
                busy = true
                session.mockIngest(status())
            case "interrupt":
                busy = false
                session.mockIngest(event("system", ["subtype": "informational", "text": "中断しました"]))
                session.mockIngest(status())
            case "select":
                seq = 0
                session.mockIngest(status())
                for line in history() { session.mockIngest(line) }
            default:
                break
            }
        }
    }

    /// GET /api/claude/sessions の代わり。呼ばれるたびに中身が少し変わる(ポーリングで一覧が更新される状況)。
    func sessions() -> [ClaudeSessionInfo] {
        q.sync {
            sessionPolls += 1
            let n = 2 + sessionPolls % 3
            return (0..<n).map { i in
                ClaudeSessionInfo(sessionID: i == 0 ? "mock" : "mock\(i)", name: i == 0 ? "converse" : "作業\(i)",
                                  cwd: "/tmp/w\(i)", status: (i + sessionPolls) % 2 == 0 ? "busy" : "idle", channel: i != 2)
            }
        }
    }

    // MARK: 台本

    private func history() -> [String] {
        [
            event("user", ["text": "README の見出しを整えて", "source": "human"]),
            event("thinking", ["text": "", "redacted": true]),
            event("tool_use", ["id": "toolu_h1", "name": "Bash", "input": ["command": "ls -la", "description": "一覧を見る"]]),
            event("tool_result", ["tool_use_id": "toolu_h1", "is_error": false, "text": "total 8\n-rw-r--r-- README.md"]),
            event("tool_use", ["id": "toolu_h2", "name": "Read", "input": ["file_path": "/tmp/mock/README.md"]]),
            event("tool_result", ["tool_use_id": "toolu_h2", "is_error": false, "text": "# 旧い見出し"]),
            event("tool_use", ["id": "toolu_h3", "name": "Edit", "input": ["file_path": "/tmp/mock/README.md",
                                                                          "old_string": "# 旧い見出し", "new_string": "# 新しい見出し"]]),
            event("tool_result", ["tool_use_id": "toolu_h3", "is_error": false, "text": "ok"]),
            event("text", ["text": """
            ## 直しました

            **README** の見出しを `# 新しい見出し` にしました。

            - 1 行目を変更
            - 他は触っていません

            ```bash
            git diff README.md
            ```

            | 項目 | 状態 |
            |---|---|
            | 見出し | 済 |

            > 確認は [GitHub](https://github.com) で。
            """]),
            event("result", ["duration_ms": 4200, "message_count": 9]),
        ]
    }

    private func stream(_ session: ClaudeSession, tick: Int) {
        let t = tick + 1
        switch t % 5 {
        case 1:
            session.mockIngest(event("thinking", ["text": "考え中 \(t)"]))
        case 2:
            session.mockIngest(event("tool_use", ["id": "toolu_s\(t)", "name": t % 2 == 0 ? "Bash" : "Grep",
                                                  "input": ["command": "echo \(t)", "pattern": "x\(t)"]]))
        case 3:
            session.mockIngest(event("tool_result", ["tool_use_id": "toolu_s\(t - 1)", "is_error": t % 15 == 3,
                                                     "text": "出力 \(t)\n" + String(repeating: "log line\n", count: 5)]))
        case 4:
            session.mockIngest(event("text", ["text": "途中経過 \(t): **太字** と `code`"]))
        default:
            busy.toggle()
            session.mockIngest(status())
        }
        q.asyncAfter(deadline: .now() + 0.3) { [self] in stream(session, tick: t) }
    }

    // MARK: JSON

    private func event(_ kind: String, _ data: [String: Any]) -> String {
        seq += 1
        return json(["type": "event", "seq": seq, "kind": kind, "data": data, "session": "mock",
                     "at": ISO8601DateFormatter().string(from: Date())])
    }

    private func status() -> String {
        json(["type": "status", "busy": busy, "model": "claude-fable-5", "effort": "medium", "cwd": "/tmp/mock",
              "project": "モック", "session": "mock", "name": "converse", "channel": true])
    }

    private func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// UI テスト用: 入力欄(UITextView/UITextField)の編集開始・終了の回数と、メインスレッドの詰まりを数え、画面の見えない札に出す。
/// 一瞬でも外れて付け直された場合も「終了」が数えられるので、付け直しの小細工では隠せない。本番では作らない。
/// 詰まり: 0.1 秒ごとに裏から main へ投げて届くまでの遅れ(ミリ秒)を測り、100/250/500/1000 ミリ秒を超えた回数と最大を数える。
@MainActor
final class ClaudeFocusProbe: ObservableObject {
    static let shared = ClaudeFocusProbe()
    @Published private(set) var began = 0
    @Published private(set) var ended = 0
    @Published private(set) var samples = 0
    @Published private(set) var over100 = 0
    @Published private(set) var over250 = 0
    @Published private(set) var over500 = 0
    @Published private(set) var over1000 = 0
    @Published private(set) var maxStallMs = 0
    private var observers: [any NSObjectProtocol] = []
    private var stallTimer: DispatchSourceTimer?
    /// メインスレッドが使った CPU 時間(ミリ秒)。CI の機械の込み具合に左右されにくい、仕事量の目安
    private let mainThread = mach_thread_self()

    private var mainCPUMs: Int {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        let user = Int(info.user_time.seconds) * 1000 + Int(info.user_time.microseconds) / 1000
        let system = Int(info.system_time.seconds) * 1000 + Int(info.system_time.microseconds) / 1000
        return user + system
    }

    private init() {
        let c = NotificationCenter.default
        for name in [UITextView.textDidBeginEditingNotification, UITextField.textDidBeginEditingNotification] {
            observers.append(c.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClaudeFocusProbe.shared.began += 1 }
            })
        }
        for name in [UITextView.textDidEndEditingNotification, UITextField.textDidEndEditingNotification] {
            observers.append(c.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClaudeFocusProbe.shared.ended += 1 }
            })
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: .milliseconds(100))
        timer.setEventHandler { @Sendable in
            let sent = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let ms = Int((DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
                MainActor.assumeIsolated { ClaudeFocusProbe.shared.noteStall(ms) }
            }
        }
        timer.resume()
        stallTimer = timer
    }

    private func noteStall(_ ms: Int) {
        samples += 1
        if ms > 100 { over100 += 1 }
        if ms > 250 { over250 += 1 }
        if ms > 500 { over500 += 1 }
        if ms > 1000 { over1000 += 1 }
        if ms > maxStallMs { maxStallMs = ms }
    }

    var summary: String {
        "begin=\(began) end=\(ended) n=\(samples) o100=\(over100) o250=\(over250) o500=\(over500) o1000=\(over1000) max=\(maxStallMs)ms cpu=\(mainCPUMs)ms"
    }
}
