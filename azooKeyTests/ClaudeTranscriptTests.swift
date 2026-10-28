//
//  ClaudeTranscriptTests.swift
//  Claude タブ: イベント列 → 表示項目(ClaudeTranscript)の純ロジックのテスト。
//  ツール呼び出しの畳み込み・連続したまとまり・結果の突き合わせ・成果物・添付・返事の結合・内部の行の隠し方。
//

import Foundation
import XCTest
@testable import azooKey

final class ClaudeTranscriptTests: XCTestCase {
    private func ev(_ seq: Int, _ kind: String, _ data: [String: Any]) -> ClaudeEvent {
        ClaudeEvent.parse(["seq": seq, "kind": kind, "data": data])!
    }

    private var sample: [ClaudeEvent] {
        [
            ev(1, "user", ["text": "見て @/home/ashwell/portal-bot/data/uploads/0123456789abcdef_photo.jpg", "source": "human"]),
            ev(2, "thinking", ["text": "", "redacted": true]),
            ev(3, "tool_use", ["id": "t1", "name": "Bash", "input": ["command": "ls -la\npwd", "description": "一覧"]]),
            ev(4, "tool_use", ["id": "t2", "name": "Read", "input": ["file_path": "/a/b/README.md"]]),
            ev(5, "tool_result", ["tool_use_id": "t1", "is_error": false, "text": "out"]),
            ev(6, "tool_use", ["id": "t3", "name": "Bash", "input": ["command": "make"]]),
            ev(7, "tool_result", ["tool_use_id": "t3", "is_error": true, "text": "boom"]),
            ev(8, "tool_use", ["id": "t4", "name": "Write", "input": ["file_path": "/data/ashwell/x/report.html", "content": "<p>"]]),
            ev(9, "text", ["text": "できました"]),
            ev(10, "text", ["text": "**続き**"]),
            ev(11, "result", ["duration_ms": 1000]),
            ev(12, "user", ["text": "x", "source": "meta", "meta": true]),
            ev(13, "tool_use", ["id": "r1", "name": "mcp__tsukaima__reply", "input": ["text": "返事です"]]),
            ev(14, "tool_result", ["tool_use_id": "r1", "text": "ok"]),
            ev(15, "tool_use", ["id": "m1", "name": "mcp__playwright__browser_click", "input": ["element": "OK button"]]),
            ev(16, "system", ["subtype": "local_command", "text": "Set effort"]),
            ev(17, "system", ["subtype": "informational", "text": "hook"]),
            ev(18, "error", ["text": "401"]),
        ]
    }

    func testFoldsToolsIntoOneActivityAndMatchesResults() {
        let items = ClaudeTranscript.build(sample, showDetails: false)
        XCTAssertEqual(items.count, 8)
        guard case .activity(let act) = items[1] else { return XCTFail("2 番目はまとまり") }
        XCTAssertEqual(act.calls.count, 4, "連続したツール呼び出しは 1 つのまとまり")
        XCTAssertEqual(act.summary, "コマンド 2・読む 1・作成 1")
        XCTAssertEqual(act.errorCount, 1)
        XCTAssertEqual(act.calls[0].output, "out")
        XCTAssertEqual(act.calls[0].title, "一覧", "Bash は説明を要約に使う")
        XCTAssertFalse(act.calls[1].hasResult)
        XCTAssertTrue(act.hasPending)
        XCTAssertFalse(act.steps.contains { if case .thinking = $0 { return true } else { return false } }, "伏せ字の thinking は出さない")
    }

    func testUserAttachmentsAreSplitFromText() {
        let items = ClaudeTranscript.build(sample, showDetails: false)
        guard case .user(_, let text, let refs, let voice) = items[0] else { return XCTFail() }
        XCTAssertEqual(text, "見て")
        XCTAssertEqual(refs.count, 1)
        XCTAssertTrue(refs[0].isImage)
        XCTAssertEqual(refs[0].name, "photo.jpg", "アップロード id の接頭辞は表示名から外す")
        XCTAssertFalse(voice)
    }

    func testArtifactCardAfterActivity() {
        let items = ClaudeTranscript.build(sample, showDetails: false)
        guard case .artifact(_, let path, let kind, let edited) = items[2] else { return XCTFail() }
        XCTAssertEqual(path, "/data/ashwell/x/report.html")
        XCTAssertEqual(kind, .html)
        XCTAssertFalse(edited)
    }

    func testAssistantTextMergesWithinTurnButNotAcrossTurns() {
        let items = ClaudeTranscript.build(sample, showDetails: false)
        guard case .assistant(_, let a) = items[3], case .assistant(_, let b) = items[4] else { return XCTFail() }
        XCTAssertEqual(a, "できました\n\n**続き**")
        XCTAssertEqual(b, "返事です", "ターンをまたいだ返事は別のメッセージ・reply ツールは返事として出す")
    }

    func testMCPToolNamesAndHiddenLines() {
        let items = ClaudeTranscript.build(sample, showDetails: false)
        guard case .activity(let act) = items[5] else { return XCTFail() }
        XCTAssertEqual(act.summary, "browser_click playwright")
        guard case .note(_, let t, _) = items[6] else { return XCTFail() }
        XCTAssertEqual(t, "Set effort", "ローカルコマンドの応答は常に 1 行で出す")
        guard case .error = items[7] else { return XCTFail() }
        XCTAssertEqual(ClaudeTranscript.build(sample, showDetails: true).count, 11, "詳細表示では内部の行・完了も出す")
    }

    func testStableIDsWhenEventsAppend() {
        let first = ClaudeTranscript.build(Array(sample.prefix(9)), showDetails: false).map(\.id)
        let later = ClaudeTranscript.build(sample, showDetails: false).map(\.id)
        XCTAssertEqual(Array(later.prefix(first.count)), first, "後からイベントが増えても前の項目の id は変わらない")
    }

    func testToolSummaries() {
        let edit = ClaudeTranscript.toolCall(ev(1, "tool_use", ["id": "e", "name": "Edit",
                                                                  "input": ["file_path": "/x/y.swift", "old_string": "a", "new_string": "b"]]))
        XCTAssertEqual(edit.verb, "編集")
        XCTAssertEqual(edit.title, "y.swift")
        XCTAssertEqual(edit.edit, ClaudeEditDiff(old: "a", new: "b"))
        let grep = ClaudeTranscript.toolCall(ev(2, "tool_use", ["id": "g", "name": "Grep", "input": ["pattern": "foo", "path": "/a/src"]]))
        XCTAssertEqual(grep.title, "foo (src)")
        let todo = ClaudeTranscript.toolCall(ev(3, "tool_use", ["id": "t", "name": "TodoWrite",
                                                                  "input": ["todos": [["content": "A", "status": "completed"], ["content": "B", "status": "pending"]]]]))
        XCTAssertEqual(todo.input, "☑︎ A\n☐ B")
        let long = ClaudeTranscript.toolCall(ev(4, "tool_use", ["id": "b", "name": "Bash", "input": ["command": String(repeating: "x", count: 200)]]))
        XCTAssertLessThanOrEqual(long.title.count, 80)
    }

    func testLargeHistoryBuildsQuickly() {
        var evs: [ClaudeEvent] = []
        for i in 0..<4000 {
            switch i % 4 {
            case 0: evs.append(ev(i, "tool_use", ["id": "t\(i)", "name": "Bash", "input": ["command": "echo \(i)"]]))
            case 1: evs.append(ev(i, "tool_result", ["tool_use_id": "t\(i - 1)", "text": "out \(i)"]))
            case 2: evs.append(ev(i, "text", ["text": "途中 \(i)"]))
            default: evs.append(ev(i, "user", ["text": "u \(i)", "source": "human"]))
            }
        }
        let start = Date()
        let items = ClaudeTranscript.build(evs, showDetails: false)
        XCTAssertEqual(items.count, 3000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "4000 件のイベントを 1 秒以内に項目にできる")
    }
}
