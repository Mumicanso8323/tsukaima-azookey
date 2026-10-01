import Foundation

/// UI テスト用の台本(起動引数 `--claude-mock`、ClaudeConfig.isMock)。サーバー無しで、実機で起きる状態変化を
/// 一通り再現する: 高頻度のイベント・ツール状態の更新・busy/idle の切替・セッション一覧の更新・
/// 切断→再接続・ターン終了・選択肢(choice)の表示と消去。ClaudeSession.handleText と同じ経路に流す。
/// 本番では一切動かない(connect() が isMock のときだけ呼ぶ)。
final class ClaudeMockDriver: @unchecked Sendable {
    static let shared = ClaudeMockDriver()
    private var task: Task<Void, Never>?
    private var seq = 0

    func start(_ session: ClaudeSession) {
        guard task == nil else { return }
        task = Task { [weak self, weak session] in
            guard let self, let session else { return }
            await self.run(session)
        }
    }

    private func event(_ kind: String, _ data: [String: Any], session: String = "mock") -> String {
        seq += 1
        let obj: [String: Any] = ["type": "event", "seq": seq, "kind": kind, "data": data, "session": session,
                                  "at": ISO8601DateFormatter().string(from: Date())]
        return json(obj)
    }

    private func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    private func status(busy: Bool) -> String {
        json(["type": "status", "busy": busy, "model": "claude-fable-5", "effort": "medium", "cwd": "/tmp/mock",
              "project": "モック", "session": "mock", "name": "converse", "channel": true])
    }

    private func sessions(_ n: Int) -> [ClaudeSessionInfo] {
        (0..<n).map { i in
            ClaudeSessionInfo(sessionID: "s\(i)", name: i == 0 ? "converse" : "作業\(i)", cwd: "/tmp/w\(i)",
                              status: i % 2 == 0 ? "busy" : "idle", channel: i != 2)
        }
    }

    private func sleep(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    private func run(_ s: ClaudeSession) async {
        s.mockIngest(status(busy: false))
        s.mockSetSessions(sessions(2))
        await sleep(500)
        s.mockIngest(event("text", ["text": "こんにちは。これはモックのセッションです。"]))
        await sleep(2500)
        // ---- ターン開始: 30 秒ほど 1 秒に 4 件のイベントを流し続ける(本人が打鍵している最中を想定) ----
        s.mockIngest(event("user", ["text": "テスト", "source": "human"]))
        s.mockIngest(status(busy: true))
        var toolIDs: [String] = []
        let started = Date()
        var tick = 0
        while Date().timeIntervalSince(started) < 30 {
            tick += 1
            switch tick % 4 {
            case 1:
                s.mockIngest(event("thinking", ["text": "考え中 \(tick)…"]))
            case 2:
                let id = "toolu_\(tick)"
                toolIDs.append(id)
                s.mockIngest(event("tool_use", ["id": id, "name": tick % 8 == 2 ? "Bash" : "Read",
                                                "input": ["command": "echo \(tick)"]]))
            case 3:
                if let id = toolIDs.first {
                    toolIDs.removeFirst()
                    s.mockIngest(event("tool_result", ["tool_use_id": id, "is_error": tick % 12 == 3, "text": "出力 \(tick)"]))
                }
            default:
                s.mockIngest(event("text", ["text": "途中経過 \(tick)"]))
            }
            if tick % 16 == 0 { s.mockSetSessions(sessions(2 + (tick / 16) % 3)) }   // 一覧が 4 秒ごとに変わる
            if tick % 20 == 0 { s.mockIngest(status(busy: tick % 40 != 0)) }         // busy/idle が切り替わる
            if tick == 48 {
                // 切断→再接続(点が灰→緑)
                s.mockSetLinkState(.reconnecting)
                await sleep(800)
                s.mockSetLinkState(.open)
                s.mockIngest(status(busy: true))
            }
            if tick == 64 {
                // セッション終了→新しいターン
                s.mockIngest(event("result", ["duration_ms": 1234]))
                s.mockIngest(event("system", ["subtype": "bridge_status", "text": "セッションが終了しました"]))
                s.mockIngest(status(busy: false))
                await sleep(500)
                s.mockIngest(event("user", ["text": "つづき", "source": "human"]))
                s.mockIngest(status(busy: true))
            }
            if tick == 80 {
                // 選択肢が出る
                s.mockIngest(json(["type": "choice", "tool_use_id": "toolu_ask1", "session": "mock", "questions": [
                    ["index": 0, "question": "どちらにしますか?", "header": "方針", "multi_select": false,
                     "options": [["index": 0, "label": "A 案", "description": ""], ["index": 1, "label": "B 案", "description": ""]]],
                ]]))
            }
            await sleep(250)
        }
        // ターンが終わる。選択肢はアプリが答えれば手元で消える(hub の消去は 45 秒後に真似る)
        s.mockIngest(event("result", ["duration_ms": 30000]))
        s.mockIngest(status(busy: false))
        await sleep(45_000)
        s.mockIngest(json(["type": "choice", "tool_use_id": "toolu_ask1", "session": "mock", "questions": NSNull()]))
    }
}
