//
//  TsukaimaClaudeTabTests.swift
//  Claude タブの純ロジック: ツール実行の集計(状態行)・フォーカス意図の状態機械・選択肢の操作・
//  キー割り当ての表・コードブロックの分割。
//

import Foundation
import UIKit
import XCTest
@testable import azooKey

final class TsukaimaClaudeTabTests: XCTestCase {
    private var seq = 0

    private func ev(_ kind: String, _ data: [String: Any] = [:]) -> ClaudeEvent {
        seq += 1
        return ClaudeEvent.parse(["seq": seq, "kind": kind, "data": data])!
    }

    // MARK: ClaudeToolActivity(状態行)

    func testThinkingWithoutTools() {
        let a = ClaudeToolActivity.reduce([ev("user", ["text": "やって"]), ev("thinking", ["text": "…"])])
        XCTAssertEqual(a.line(busy: true), "思考中…")
        XCTAssertEqual(a.line(busy: false), "")
        XCTAssertTrue(a.turnOpen)
    }

    func testRunningToolsAreCounted() {
        let a = ClaudeToolActivity.reduce([
            ev("user", ["text": "やって"]),
            ev("tool_use", ["id": "t1", "name": "Bash"]),
            ev("tool_use", ["id": "t2", "name": "Read"]),
            ev("tool_use", ["id": "t3", "name": "Grep"]),
        ])
        XCTAssertEqual(a.running, 3)
        XCTAssertEqual(a.line(busy: true), "思考中…(3件のツールを実行中…)")
    }

    func testFinishedTurnShowsSuccessAndFailure() {
        let a = ClaudeToolActivity.reduce([
            ev("user", ["text": "やって"]),
            ev("tool_use", ["id": "t1", "name": "Bash"]),
            ev("tool_result", ["tool_use_id": "t1", "is_error": false]),
            ev("tool_use", ["id": "t2", "name": "Read"]),
            ev("tool_result", ["tool_use_id": "t2", "is_error": true]),
            ev("result", [:]),
        ])
        XCTAssertFalse(a.turnOpen)
        XCTAssertEqual(a.succeeded, 1)
        XCTAssertEqual(a.failed, 1)
        XCTAssertEqual(a.line(busy: false), "(1件のツールが成功、1件が失敗)")
    }

    func testFailurePartOmittedWhenZero() {
        let a = ClaudeToolActivity.reduce([
            ev("user", ["text": "やって"]),
            ev("tool_use", ["id": "t1", "name": "Bash"]),
            ev("tool_result", ["tool_use_id": "t1"]),
            ev("tool_use", ["id": "t2", "name": "Bash"]),
            ev("tool_result", ["tool_use_id": "t2"]),
            ev("result", [:]),
        ])
        XCTAssertEqual(a.line(busy: false), "(2件のツールが成功)")
    }

    func testOnlyCurrentTurnIsCounted() {
        let a = ClaudeToolActivity.reduce([
            ev("user", ["text": "前のターン"]),
            ev("tool_use", ["id": "old", "name": "Bash"]),
            ev("tool_result", ["tool_use_id": "old"]),
            ev("result", [:]),
            ev("user", ["text": "いまのターン"]),
            ev("tool_use", ["id": "new", "name": "Read"]),
        ])
        XCTAssertEqual(a.items.map(\.id), ["new"])
        XCTAssertEqual(a.line(busy: true), "思考中…(1件のツールを実行中…)")
    }

    func testMetaUserAndReplyToolAreIgnored() {
        let a = ClaudeToolActivity.reduce([
            ev("user", ["text": "やって"]),
            ev("tool_use", ["id": "t1", "name": "Bash"]),
            ev("user", ["text": "<local-command-stdout>x</local-command-stdout>", "source": "meta"]),  // ターンの区切りにしない
            ev("tool_use", ["id": "r1", "name": "mcp__tsukaima__reply", "input": ["text": "返事"]]),
        ])
        XCTAssertEqual(a.items.map(\.id), ["t1"])
    }

    // MARK: ComposerFocusIntent(フォーカス意図)

    func testFocusRestoredWhenEditingEndsWithoutDismiss() {
        var i = ComposerFocusIntent()
        XCTAssertEqual(i.apply(.userBeganEditing), .none)
        XCTAssertTrue(i.wantsFocus)
        // メニュー・シート・再描画・再接続で UIKit が手放しても付け直す
        XCTAssertEqual(i.apply(.editingEnded), .restore)
        XCTAssertEqual(i.apply(.editingEnded), .restore)
        XCTAssertTrue(i.wantsFocus)
    }

    func testSendKeepsFocus() {
        var i = ComposerFocusIntent()
        _ = i.apply(.userBeganEditing)
        XCTAssertEqual(i.apply(.sent), .restore)
        XCTAssertTrue(i.wantsFocus)
    }

    func testExplicitDismissStopsRestoring() {
        var i = ComposerFocusIntent()
        _ = i.apply(.userBeganEditing)
        XCTAssertEqual(i.apply(.userDismissed), .none)
        XCTAssertFalse(i.wantsFocus)
        XCTAssertEqual(i.apply(.editingEnded), .none)
        XCTAssertEqual(i.apply(.sent), .none)
    }

    func testNoRestoreBeforeUserEverFocused() {
        var i = ComposerFocusIntent()
        XCTAssertEqual(i.apply(.editingEnded), .none)
        XCTAssertEqual(i.apply(.parentRequestedFocus), .none)
        XCTAssertTrue(i.wantsFocus)
    }

    // MARK: ClaudeChoice(選択肢)

    private func choice(multi: Bool = false, questions: Int = 1) -> ClaudeChoice {
        let qs: [[String: Any]] = (0..<questions).map { i in
            ["index": i, "question": "Q\(i)", "header": "H", "multi_select": multi,
             "options": [["index": 0, "label": "A"], ["index": 1, "label": "B"], ["index": 2, "label": "C"]]]
        }
        guard case .show(let c)? = ClaudeChoice.parse(["tool_use_id": "toolu_1", "session": "s", "questions": qs]) else {
            fatalError("parse failed")
        }
        return c
    }

    func testChoiceParseAndClear() {
        XCTAssertEqual(choice().questions.count, 1)
        XCTAssertEqual(choice().questions[0].options.map(\.label), ["A", "B", "C"])
        XCTAssertEqual(ClaudeChoice.parse(["tool_use_id": "toolu_1", "questions": NSNull()]), .cleared("toolu_1"))
        XCTAssertNil(ClaudeChoice.parse(["questions": NSNull()]))
    }

    func testDigitPicksAndSubmitsSingleSelect() {
        var s = ClaudeChoiceSelection(choice: choice())
        XCTAssertEqual(s.handle(.digit(2), composerText: ""), .submit([.init(questionIndex: 0, selected: [1], otherText: nil)]))
    }

    func testDigitIsTypedNormallyWhenComposerHasText() {
        var s = ClaudeChoiceSelection(choice: choice())
        XCTAssertNil(s.handle(.digit(2), composerText: "abc"))
        XCTAssertNil(s.handle(.up, composerText: "abc"))
    }

    func testArrowsAndEnterSingleSelect() {
        var s = ClaudeChoiceSelection(choice: choice())
        XCTAssertEqual(s.handle(.down, composerText: ""), .changed)
        XCTAssertEqual(s.handle(.down, composerText: ""), .changed)
        XCTAssertEqual(s.handle(.down, composerText: ""), .changed)  // 端で止まる
        XCTAssertEqual(s.highlighted, 2)
        XCTAssertEqual(s.handle(.up, composerText: ""), .changed)
        XCTAssertEqual(s.handle(.enter, composerText: ""), .submit([.init(questionIndex: 0, selected: [1], otherText: nil)]))
    }

    func testEnterWithTextIsOther() {
        var s = ClaudeChoiceSelection(choice: choice())
        XCTAssertEqual(s.handle(.enter, composerText: " 別案で "),
                       .submit([.init(questionIndex: 0, selected: [], otherText: "別案で")]))
    }

    func testMultiSelectSpaceAndDigitToggleThenEnter() {
        var s = ClaudeChoiceSelection(choice: choice(multi: true))
        XCTAssertEqual(s.handle(.enter, composerText: ""), .ignored)  // 何も選んでいない
        XCTAssertEqual(s.handle(.space, composerText: ""), .changed)    // A
        XCTAssertEqual(s.handle(.digit(3), composerText: ""), .changed) // C
        XCTAssertEqual(s.handle(.digit(3), composerText: ""), .changed) // C を外す
        XCTAssertEqual(s.handle(.digit(2), composerText: ""), .changed) // B
        XCTAssertEqual(s.checked, [0, 1])
        XCTAssertEqual(s.handle(.enter, composerText: ""), .submit([.init(questionIndex: 0, selected: [0, 1], otherText: nil)]))
    }

    func testMultipleQuestionsAnsweredInOrder() {
        var s = ClaudeChoiceSelection(choice: choice(questions: 2))
        XCTAssertEqual(s.handle(.digit(1), composerText: ""), .changed)
        XCTAssertEqual(s.questionIndex, 1)
        XCTAssertEqual(s.pick(number: 3), .submit([
            .init(questionIndex: 0, selected: [0], otherText: nil),
            .init(questionIndex: 1, selected: [2], otherText: nil),
        ]))
    }

    func testEscapeIsNotConsumedByChoice() {
        var s = ClaudeChoiceSelection(choice: choice())
        XCTAssertNil(s.handle(.escape, composerText: ""))
    }

    func testAnswerJSON() {
        let j = ClaudeChoiceSelection.Answer(questionIndex: 0, selected: [1], otherText: nil).json
        XCTAssertEqual(j["question_index"] as? Int, 0)
        XCTAssertEqual(j["selected"] as? [Int], [1])
        XCTAssertTrue(j["other_text"] is NSNull)
    }

    // MARK: ComposerKeyBinding(キー割り当ての表)

    func testKeyBindingTableIsUnambiguous() {
        var seen: [String: ComposerKeyBinding] = [:]
        for b in ComposerKeyBinding.allCases {
            XCTAssertFalse(b.specs.isEmpty, "\(b) に割り当てが無い")
            for spec in b.specs {
                let key = "\(spec.input)/\(spec.modifiers.rawValue)"
                XCTAssertNil(seen[key], "\(key) が \(String(describing: seen[key])) と \(b) で重複")
                seen[key] = b
                XCTAssertEqual(ComposerKeyBinding.match(input: spec.input, modifiers: spec.modifiers), b)
            }
        }
        // 素の ↑/↓/数字は表に無い(入力欄のカーソル移動と選択肢に残す)
        XCTAssertNil(ComposerKeyBinding.match(input: UIKeyCommand.inputUpArrow, modifiers: []))
        XCTAssertNil(ComposerKeyBinding.match(input: "1", modifiers: []))
        XCTAssertEqual(ComposerKeyBinding.match(input: "3", modifiers: .command), .choose3)
        XCTAssertEqual(ComposerKeyBinding.choose(9), .choose9)
        XCTAssertNil(ComposerKeyBinding.choose(10))
    }

    // MARK: コードブロックの分割

    func testCodeBlockSplit() {
        let segs = ClaudeMessageSegment.split("前\n```swift\nlet a = 1\n```\n後")
        XCTAssertEqual(segs, [.text("前\n"), .code("let a = 1"), .text("\n後")])
        XCTAssertEqual(ClaudeMessageSegment.split("だけ"), [.text("だけ")])
        XCTAssertEqual(ClaudeMessageSegment.split("```\nx\n"), [.code("x")])  // 閉じていない
    }
}
