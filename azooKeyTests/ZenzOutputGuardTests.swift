//
//  ZenzOutputGuardTests.swift
//  使い魔azooKey: zenz の壊れた変換候補を候補欄に出さない判定のテスト
//  2026-11-19 本人の報告で、読み「あか」に「〔?ア〕〔?〕〔?〕〔?〕〔?〕か」が出た。
//

import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardViews
import XCTest

final class ZenzOutputGuardTests: XCTestCase {
    private let garbage = "〔?ア〕〔?〕〔?〕〔?〕〔?〕か"

    private func candidate(_ text: String, ruby: String, userDictionary: Bool = false, learned: Bool = false) -> Candidate {
        var metadata: DicdataElementMetadata = []
        if userDictionary { metadata.insert(.isFromUserDictionary) }
        if learned { metadata.insert(.isLearned) }
        let element = DicdataElement(word: text, ruby: ruby, cid: 0, mid: 0, value: 0, metadata: metadata)
        return Candidate(text: text, value: 0, composingCount: .inputCount(ruby.count), lastMid: 0, data: [element])
    }

    func testDropsZenzBrokenCandidateForAka() {
        XCTAssertEqual(ZenzOutputText.judge(text: garbage, reading: "あか", isFromUserDictionary: false), .drop(.brokenCharacter))
    }

    func testKeepsKaomojiAndOrdinaryCandidates() {
        let cases: [(text: String, reading: String)] = [
            ("ヽ〔ﾟДﾟ〕丿", "かおもじ"),
            ("赤", "あか"),
            ("明るめ", "あかるめ"),
            ("？", "あか"),
        ]
        for item in cases {
            XCTAssertEqual(
                ZenzOutputText.judge(text: item.text, reading: item.reading, isFromUserDictionary: false),
                .keep,
                item.text
            )
        }
    }

    func testQuestionMarkKeptWhenReadingHasIt() {
        XCTAssertEqual(ZenzOutputText.judge(text: "?", reading: "?", isFromUserDictionary: false), .keep)
    }

    func testReplacementCharacterDroppedUnlessInReading() {
        XCTAssertEqual(ZenzOutputText.judge(text: "\u{FFFD}ア", reading: "あ", isFromUserDictionary: false), .drop(.brokenCharacter))
        XCTAssertEqual(ZenzOutputText.judge(text: "\u{FFFD}ア", reading: "\u{FFFD}あ", isFromUserDictionary: false), .keep)
    }

    func testDropsRunawayRepeatButKeepsRepeatInReading() {
        XCTAssertEqual(ZenzOutputText.judge(text: "ごめんごめんごめん", reading: "ごめん", isFromUserDictionary: false), .drop(.repeatRun))
        XCTAssertEqual(ZenzOutputText.judge(text: "ごめんごめんごめん", reading: "ごめんごめんごめん", isFromUserDictionary: false), .keep)
        XCTAssertEqual(ZenzOutputText.judge(text: "ニャンニャンニャン", reading: "にゃんにゃんにゃん", isFromUserDictionary: false), .keep)
        XCTAssertEqual(ZenzOutputText.judge(text: "あいうあいうあいう", reading: "あいう", isFromUserDictionary: false), .drop(.repeatRun))
    }

    func testTwoRepeatsAreNotDroppedButAreNearMiss() {
        XCTAssertEqual(ZenzOutputText.judge(text: "ドキドキ", reading: "どきどき", isFromUserDictionary: false), .keep)
        XCTAssertEqual(ZenzOutputText.judge(text: "ハハハハ", reading: "わははは", isFromUserDictionary: false), .nearRepeat)
    }

    func testUserDictionaryOriginIsKeptButReported() {
        XCTAssertEqual(
            ZenzOutputText.judge(text: garbage, reading: "あか", isFromUserDictionary: true),
            .keepUserDictionary(.brokenCharacter)
        )
    }

    func testScreenDropsOnlyZenzBrokenCandidates() {
        let main = [
            candidate("明るめ", ruby: "あかるめ"),
            candidate(garbage, ruby: "あか"),
            candidate("赤", ruby: "あか"),
            candidate("ヽ〔ﾟДﾟ〕丿", ruby: "かおもじ", userDictionary: true),
        ]
        let screened = ZenzOutputGuard.screen(mainResults: main, firstClauseResults: [main[1]], reading: "あか")
        XCTAssertEqual(screened.mainResults.map(\.text), ["明るめ", "赤", "ヽ〔ﾟДﾟ〕丿"])
        XCTAssertEqual(screened.firstClauseResults.count, 0)
        XCTAssertEqual(screened.findings.map(\.kindLabel), ["drop-broken-char", "drop-broken-char"])
        XCTAssertEqual(screened.findings.map(\.source), ["dict-or-zenz", "dict-or-zenz"])
    }

    func testScreenKeepsUserDictionaryCandidateWithBrokenCharacter() {
        let userCandidate = candidate(garbage, ruby: "あか", userDictionary: true)
        let screened = ZenzOutputGuard.screen(mainResults: [userCandidate], firstClauseResults: [], reading: "あか")
        XCTAssertEqual(screened.mainResults.map(\.text), [garbage])
        XCTAssertEqual(screened.findings.map(\.kindLabel), ["keep-userdict-broken-char"])
        XCTAssertEqual(screened.findings.map(\.source), ["userdict"])
    }

    func testSourceReportsLearnedFlag() {
        XCTAssertEqual(ZenzOutputGuard.source(of: candidate("赤", ruby: "あか", learned: true)), "learned")
        XCTAssertEqual(ZenzOutputGuard.source(of: candidate("赤", ruby: "あか")), "dict-or-zenz")
    }

    func testBreadcrumbLineHoldsOnlyCandidateAndReading() {
        let screened = ZenzOutputGuard.screen(mainResults: [candidate(garbage, ruby: "あか")], firstClauseResults: [], reading: "あか")
        XCTAssertEqual(screened.findings.count, 1)
        XCTAssertEqual(
            screened.findings[0].breadcrumbLine(leftContextLength: 12, effort: "high"),
            "zenzguard drop-broken-char src=dict-or-zenz reading=あか text=〔?ア〕〔?〕〔?〕〔?〕〔?〕か left=12 effort=high"
        )
    }
}
