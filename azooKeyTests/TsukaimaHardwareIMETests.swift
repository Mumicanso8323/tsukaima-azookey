//
//  TsukaimaHardwareIMETests.swift
//  本体アプリ内のハードウェアキーボード変換(HardwareIMECore)の状態機械のテスト。
//  変換器は固定の候補を返すスタブに差し替える(辞書に依存しない)。
//

import AzooKeyUtils
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest
@testable import azooKey

@MainActor
private final class StubProvider: HardwareIMEConversionProvider {
    /// 読み(ひらがな) → 候補。表記の後ろに "/n" を付けると先頭 n 文字だけを変換する文節候補
    var table: [String: [String]] = [
        "かんじ": ["漢字", "感じ"],
        "かん": ["缶", "感"],
        "か": ["蚊"],
        "きょう": ["今日", "京"],
        "きょうはかんじ": ["今日は/4", "今日はかんじ"],
        "らーめん": ["ラーメン"],
        "にほんご": ["日本語"],
    ]
    var completed: [(text: String, ended: Bool)] = []
    var cancels = 0
    var lastLeftContext = ""

    func candidates(for composing: ComposingText, leftContext: String) -> [Candidate] {
        lastLeftContext = leftContext
        let key = composing.convertTarget
        return (table[key] ?? []).map { spec in
            let parts = spec.split(separator: "/")
            let count = parts.count > 1 ? Int(parts[1])! : key.count
            return Candidate(text: String(parts[0]), value: 0, composingCount: .surfaceCount(count), lastMid: 0, data: [])
        }
    }

    func didComplete(_ candidate: Candidate, compositionEnded: Bool) {
        completed.append((candidate.text, compositionEnded))
    }

    func didCancel() {
        cancels += 1
    }
}

@MainActor
final class TsukaimaHardwareIMETests: XCTestCase {
    private var provider: StubProvider!
    private var ime: HardwareIMECore!

    override func setUp() async throws {
        provider = StubProvider()
        ime = HardwareIMECore(provider: provider, leftContext: { "左文脈" })
    }

    private func type(_ s: String) -> [HardwareIMEEffect] {
        var effects: [HardwareIMEEffect] = []
        for c in s {
            let r = ime.handle(.character(c))
            XCTAssertTrue(r.handled, "\(c) should be handled")
            effects += r.effects
        }
        return effects
    }

    func testRomajiBecomesMarkedKana() {
        let effects = type("kanji")
        XCTAssertEqual(effects.last, .setMarked("かんじ", cursor: 3))
        XCTAssertTrue(ime.isComposing)
        XCTAssertFalse(ime.isConverting)
        XCTAssertEqual(ime.candidates.map(\.text), ["漢字", "感じ"])
        XCTAssertEqual(provider.lastLeftContext, "左文脈")
    }

    func testSpaceCyclesCandidatesAndEnterCommits() {
        _ = type("kanji")
        XCTAssertEqual(ime.handle(.space).effects, [.setMarked("漢字", cursor: 2)])
        XCTAssertEqual(ime.handle(.space).effects, [.setMarked("感じ", cursor: 2)])
        XCTAssertEqual(ime.handle(.space).effects, [.setMarked("漢字", cursor: 2)]) // 末尾で先頭に戻る
        XCTAssertEqual(ime.handle(.shiftSpace).effects, [.setMarked("感じ", cursor: 2)])
        XCTAssertEqual(ime.handle(.up).effects, [.setMarked("漢字", cursor: 2)])
        XCTAssertEqual(ime.handle(.down).effects, [.setMarked("感じ", cursor: 2)])
        XCTAssertEqual(ime.handle(.tab).effects, [.setMarked("漢字", cursor: 2)])
        let r = ime.handle(.enter)
        XCTAssertEqual(r.effects, [.commit("漢字")])
        XCTAssertFalse(ime.isComposing)
        XCTAssertEqual(provider.completed.map { $0.text }, ["漢字"])
        XCTAssertEqual(provider.completed.map { $0.ended }, [true])
    }

    func testEnterWithoutConversionCommitsKanaAndFixesTrailingN() {
        _ = type("kan")
        XCTAssertEqual(ime.displayText, "かn")
        XCTAssertEqual(ime.handle(.enter).effects, [.commit("かん")])
        XCTAssertTrue(provider.completed.isEmpty)
        XCTAssertEqual(provider.cancels, 1)
    }

    func testKeysPassThroughWhenNotComposing() {
        for key in [HardwareIMEKey.space, .enter, .escape, .tab, .backspace, .up, .down, .left, .right, .f7, .deleteForward] {
            XCTAssertEqual(ime.handle(key), .passThrough, "\(key)")
        }
        XCTAssertEqual(ime.handle(.character("1")), .passThrough)
        XCTAssertEqual(ime.handle(.character("!")), .handled([.commit("！")])) // Shift+記号の既存処理
        XCTAssertEqual(ime.handle(.character("あ")), .passThrough) // OS 側で既に日本語
    }

    func testEscapeRevertsThenCancels() {
        _ = type("kanji")
        _ = ime.handle(.space)
        XCTAssertEqual(ime.handle(.escape).effects, [.setMarked("かんじ", cursor: 3)])
        XCTAssertFalse(ime.isConverting)
        XCTAssertEqual(ime.handle(.escape).effects, [.clearMarked])
        XCTAssertFalse(ime.isComposing)
        XCTAssertEqual(provider.cancels, 1)
    }

    func testBackspaceRevertsSelectionThenDeletesKana() {
        _ = type("kanji")
        _ = ime.handle(.space)
        XCTAssertEqual(ime.handle(.backspace).effects, [.setMarked("かんじ", cursor: 3)])
        XCTAssertEqual(ime.handle(.backspace).effects, [.setMarked("かん", cursor: 2)])
        XCTAssertEqual(ime.candidates.map(\.text), ["缶", "感"])
        XCTAssertEqual(ime.handle(.backspace).effects, [.setMarked("か", cursor: 1)])
        XCTAssertEqual(ime.handle(.backspace).effects, [.clearMarked])
        XCTAssertFalse(ime.isComposing)
        XCTAssertEqual(ime.handle(.backspace), .passThrough)
    }

    func testAlnumModePassesEverything() {
        XCTAssertEqual(ime.handle(.toggleMode), .handled([]))
        XCTAssertEqual(ime.mode, .alnum)
        XCTAssertEqual(ime.handle(.character("k")), .passThrough)
        XCTAssertEqual(ime.handle(.character(",")), .passThrough)
        XCTAssertEqual(ime.handle(.space), .passThrough)
        XCTAssertEqual(ime.handle(.toKana), .handled([]))
        XCTAssertEqual(ime.mode, .kana)
        XCTAssertEqual(ime.handle(.toAlnum).handled, true)
        XCTAssertEqual(ime.mode, .alnum)
    }

    func testModeSwitchWhileComposingCommitsWhatIsShown() {
        _ = type("kanji")
        _ = ime.handle(.space)
        XCTAssertEqual(ime.handle(.toggleMode).effects, [.commit("漢字")])
        XCTAssertEqual(ime.mode, .alnum)
        XCTAssertFalse(ime.isComposing)
    }

    func testPunctuation() {
        XCTAssertEqual(ime.handle(.character(",")).effects, [.commit("、")])
        XCTAssertEqual(ime.handle(.character("?")).effects, [.commit("？")])
        _ = type("kanji")
        XCTAssertEqual(ime.handle(.character(".")).effects, [.setMarked("かんじ。", cursor: 4)])
        XCTAssertTrue(ime.isComposing)
        _ = ime.cancelAll()
        _ = type("kanji")
        _ = ime.handle(.space)
        XCTAssertEqual(ime.handle(.character(".")).effects, [.commit("漢字"), .commit("。")])
    }

    func testPunctuationResolvesTrailingNInsideComposition() {
        _ = type("kan")
        XCTAssertEqual(ime.handle(.character(".")).effects, [.setMarked("かん。", cursor: 3)])
        XCTAssertEqual(ime.handle(.enter).effects, [.commit("かん。")])
    }

    func testUppercaseStartsLiteralRunInsideComposition() {
        _ = type("ka")
        XCTAssertEqual(type("Nji").last, .setMarked("かNji", cursor: 4))
        XCTAssertEqual(ime.handle(.enter).effects, [.commit("かNji")])
    }

    func testHelloIsLiteralCompositionAndSpaceCommitsIt() {
        XCTAssertEqual(type("Hello").last, .setMarked("Hello", cursor: 5))
        XCTAssertEqual(ime.handle(.space).effects, [.commit("Hello"), .commit(" ")])
        XCTAssertFalse(ime.isComposing)
    }

    func testLiteralRunClearsAtSpaceAndNextWordUsesRomaji() {
        _ = type("Hello")
        XCTAssertEqual(ime.handle(.space).effects, [.commit("Hello"), .commit(" ")])
        XCTAssertEqual(type("ka").last, .setMarked("か", cursor: 1))
    }

    func testHelloWorldCommitsTheLiteralFirstWordAtSpace() {
        _ = type("Hello")
        XCTAssertEqual(ime.handle(.space).effects, [.commit("Hello"), .commit(" ")])
        _ = type("world")
        XCTAssertNotEqual(ime.displayText, "world")
    }

    func testLongVowelInsideComposition() {
        _ = type("ra")
        _ = ime.handle(.character("-"))
        let effects = type("men")
        XCTAssertEqual(effects.last, .setMarked("らーめん", cursor: 4))
        XCTAssertEqual(ime.candidates.map(\.text), ["ラーメン"])
        XCTAssertEqual(ime.handle(.f10).effects, [.setMarked("raーmen", cursor: 7)])
    }

    func testPartialClauseCommitContinuesComposition() {
        _ = type("kyouhakanji")
        XCTAssertEqual(ime.handle(.space).effects, [.setMarked("今日はかんじ", cursor: 3)]) // カーソルは候補の直後
        let r = ime.handle(.enter)
        XCTAssertEqual(r.effects, [.commit("今日は"), .setMarked("かんじ", cursor: 3)])
        XCTAssertEqual(provider.completed.map { $0.ended }, [false])
        XCTAssertTrue(ime.isComposing)
        XCTAssertEqual(ime.candidates.map(\.text), ["漢字", "感じ"])
        XCTAssertEqual(ime.handle(.space).effects, [.setMarked("漢字", cursor: 2)])
        XCTAssertEqual(ime.handle(.enter).effects, [.commit("漢字")])
        XCTAssertEqual(provider.completed.map { $0.ended }, [false, true])
    }

    func testTypingWhileConvertingCommitsFirst() {
        _ = type("kanji")
        _ = ime.handle(.space)
        let r = ime.handle(.character("k"))
        XCTAssertEqual(r.effects, [.commit("漢字"), .setMarked("k", cursor: 1)])
        XCTAssertEqual(provider.completed.map { $0.text }, ["漢字"])
    }

    func testFunctionKeys() {
        _ = type("kanji")
        XCTAssertEqual(ime.handle(.f7).effects, [.setMarked("カンジ", cursor: 3)])
        XCTAssertEqual(ime.handle(.f10).effects, [.setMarked("kanji", cursor: 5)])
        XCTAssertEqual(ime.handle(.f9).effects, [.setMarked("ｋａｎｊｉ", cursor: 5)])
        // 半角カナの濁点は結合扱いで Character 数が環境で揺れるので、文字列と「末尾にカーソル」だけ見る
        XCTAssertEqual(ime.handle(.f8).effects, [.setMarked("ｶﾝｼﾞ", cursor: "ｶﾝｼﾞ".count)])
        XCTAssertEqual(ime.displayText, "ｶﾝｼﾞ")
        XCTAssertEqual(ime.handle(.f6).effects, [.setMarked("かんじ", cursor: 3)])
        _ = ime.handle(.f7)
        XCTAssertEqual(ime.handle(.enter).effects, [.commit("カンジ")])
        XCTAssertTrue(provider.completed.isEmpty)
    }

    func testCommitCandidateByIndexAndCommitAll() {
        _ = type("kanji")
        XCTAssertEqual(ime.commitCandidate(at: 1), [.commit("感じ")])
        XCTAssertEqual(ime.commitCandidate(at: 5), [])
        _ = type("kan")
        XCTAssertEqual(ime.commitAll(), [.commit("かん")])
        XCTAssertEqual(ime.commitAll(), [])
        _ = type("ka")
        XCTAssertEqual(ime.cancelAll(), [.clearMarked])
        XCTAssertFalse(ime.isComposing)
    }

    func testCursorMovesInsideRawComposition() {
        _ = type("kanji")
        XCTAssertEqual(ime.handle(.left).effects, [.setMarked("かんじ", cursor: 2)])
        XCTAssertEqual(ime.candidates.map(\.text), ["缶", "感"]) // カーソルまでを変換対象にする
        XCTAssertEqual(ime.handle(.right).effects, [.setMarked("かんじ", cursor: 3)])
        XCTAssertEqual(ime.handle(.right).effects, [.setMarked("かんじ", cursor: 3)])
    }

    func testConvertingPrefixKeepsCursorAfterCandidate() {
        _ = type("kanji")
        _ = ime.handle(.left) // かん|じ
        XCTAssertEqual(ime.handle(.space).effects, [.setMarked("缶じ", cursor: 1)])
        XCTAssertEqual(ime.handle(.enter).effects, [.commit("缶"), .setMarked("じ", cursor: 1)]) // 残りが左端始まりならカーソルは末尾へ(ComposingText の挙動)
        XCTAssertTrue(ime.isComposing)
    }

    func testStateChangeCallbackFires() {
        var count = 0
        ime.onStateChange = { count += 1 }
        _ = type("ka")
        _ = ime.handle(.space)
        _ = ime.handle(.enter)
        XCTAssertGreaterThanOrEqual(count, 4)
    }
}

final class HardwareIMEInsertSuppressionTests: XCTestCase {
    func testReturnCRAndLFMatchInsideShortWindow() {
        XCTAssertTrue(HardwareIMEInsertSuppression.shouldSuppress(text: "\n", pending: "\r", elapsed: 0.01))
        XCTAssertTrue(HardwareIMEInsertSuppression.shouldSuppress(text: "\r", pending: "\n", elapsed: 0.29))
    }

    func testOnlyPendingRecentMatchingInputIsSuppressed() {
        XCTAssertFalse(HardwareIMEInsertSuppression.shouldSuppress(text: "\n", pending: nil, elapsed: 0.01))
        XCTAssertFalse(HardwareIMEInsertSuppression.shouldSuppress(text: "\n", pending: "\r", elapsed: 0.3))
        XCTAssertFalse(HardwareIMEInsertSuppression.shouldSuppress(text: "x", pending: "\r", elapsed: 0.01))
    }
}
