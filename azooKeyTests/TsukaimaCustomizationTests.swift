//
//  TsukaimaCustomizationTests.swift
//  使い魔azooKey で足した部分(hub ユーザ辞書・候補ブロック)のテスト
//

import AzooKeyUtils
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardViews
import XCTest

private struct TextItem: ResultViewItemData {
    var text: String
    var label: ResultViewItemLabelStyle { .text(text) }
    var inputable: Bool { true }
    #if DEBUG
    func getDebugInformation() -> String { text }
    #endif
}

private struct IconItem: ResultViewItemData {
    var label: ResultViewItemLabelStyle { .systemImage(name: "ellipsis.circle", accessibilityLabel: "ペロペロ") }
    var inputable: Bool { true }
    #if DEBUG
    func getDebugInformation() -> String { "icon" }
    #endif
}

final class TsukaimaCustomizationTests: XCTestCase {
    // MARK: CandidateBlocklist

    func testBlockMatchesSubstring() {
        XCTAssertTrue(CandidateBlocklist.isBlocked("ペロペロする", patterns: ["ペロペロ"]))
        XCTAssertTrue(CandidateBlocklist.isBlocked("ペロペロ", patterns: ["ペロペロ"]))
        XCTAssertFalse(CandidateBlocklist.isBlocked("ペロ", patterns: ["ペロペロ"]))
        XCTAssertFalse(CandidateBlocklist.isBlocked("何でも", patterns: [""]))
        XCTAssertFalse(CandidateBlocklist.isBlocked("", patterns: ["a"]))
    }

    func testMergedHubAndLocalPatterns() {
        let list = CandidateBlocklist()
        list.setHubPatterns(["ペロペロ", " "])
        list.setLocalPatterns(["変な候補", "ペロペロ"])
        XCTAssertEqual(list.patterns, ["ペロペロ", "変な候補"])
        XCTAssertTrue(list.isBlocked("変な候補です"))
        list.setHubPatterns([])
        XCTAssertTrue(list.isBlocked("ペロペロ")) // ローカル側にも残っている
        list.setLocalPatterns([])
        XCTAssertFalse(list.isBlocked("ペロペロ"))
    }

    func testFilterKeepsIconsAndOrder() {
        let list = CandidateBlocklist()
        list.setHubPatterns(["ペロペロ"])
        let items: [any ResultViewItemData] = [TextItem(text: "a"), TextItem(text: "ペロペロ舐め"), IconItem(), TextItem(text: "b")]
        let filtered = list.filter(items)
        XCTAssertEqual(filtered.count, 3)
        XCTAssertEqual(filtered.compactMap(\.textualRepresentation), ["a", "ペロペロ", "b"])
    }

    // MARK: HubUserDictionary

    func testDecodePayloadAndElements() throws {
        let json = """
        {"updated_at":"2026-09-25T00:00:00Z",
         "words":[{"word":"使い魔","reading":"つかいま","hint":"固有名詞"},
                  {"word":" 文理祭 ","reading":"ぶんりさい"},
                  {"word":"","reading":"から"},
                  {"word":"山田","reading":"やまだ","hint":"姓"}],
         "block":["ペロペロ"]}
        """
        let payload = try XCTUnwrap(HubUserDictionary.decode(Data(json.utf8)))
        XCTAssertEqual(payload.block, ["ペロペロ"])
        let elements = HubUserDictionary.elements(payload)
        XCTAssertEqual(elements.map(\.word), ["使い魔", "文理祭", "山田"])
        XCTAssertEqual(elements.map(\.ruby), ["ツカイマ", "ブンリサイ", "ヤマダ"])
        XCTAssertEqual(elements[0].lcid, CIDData.固有名詞.cid)
        XCTAssertEqual(elements[1].lcid, CIDData.一般名詞.cid)
        XCTAssertEqual(elements[2].lcid, CIDData.人名姓.cid)
    }

    func testDecodeWithoutBlock() throws {
        let payload = try XCTUnwrap(HubUserDictionary.decode(Data(#"{"words":[]}"#.utf8)))
        XCTAssertNil(payload.block)
        XCTAssertNil(HubUserDictionary.decode(Data("not json".utf8)))
    }

    func testAppendingLocalBlock() {
        XCTAssertEqual(HubUserDictionary.appending("x", to: []), ["x"])
        XCTAssertEqual(HubUserDictionary.appending("x", to: ["x"]), ["x"])
        XCTAssertEqual(HubUserDictionary.appending("  ", to: ["x"]), ["x"])
    }

    func testLocalBlockRoundTrip() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        XCTAssertEqual(HubUserDictionary.loadLocalBlock(base: base), [])
        HubUserDictionary.saveLocalBlock(["ペロペロ"], base: base)
        XCTAssertEqual(HubUserDictionary.loadLocalBlock(base: base), ["ペロペロ"])
        XCTAssertFalse(HubUserDictionary.cacheIsFresh(base: base))
    }

    // MARK: - 本体アプリ(TsukaimaImeDict)⇔キーボード(HubUserDictionary)の App Group 受け渡し

    /// 本体アプリが書く場所とキーボードが読む場所が同じであること(直接ネットを叩かなくなった代わりの契約)
    func testSharedCacheLocationMatchesMainAppWriteTarget() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(HubUserDictionary.cacheURL(base: base), TsukaimaImeDict.fileURL(base: base))
    }

    /// DynamicDictionaryComposer は本体アプリが書いたファイルの mtime が変わった時だけ読み直す(ネットには出ない)
    @MainActor
    func testDynamicDictionaryComposerReloadsOnlyWhenMainAppFileChanges() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        var applied: [[String]] = []
        let composer = DynamicDictionaryComposer(storageBase: base) { entries in
            applied.append(entries.map(\.word))
        }
        composer.setBaseEntries([])
        XCTAssertEqual(applied.last, [])

        // 本体アプリが TsukaimaAPI.shared で取得して書くのと同じ経路
        let payload = TsukaimaImeDict.Payload(words: [.init(word: "使い魔", reading: "つかいま")])
        TsukaimaImeDict.write(try JSONEncoder().encode(payload), base: base)

        composer.refreshHub()
        XCTAssertEqual(applied.last, ["使い魔"])

        // mtime が変わっていなければ何もしない(キーボードは表示のたびに呼ぶため)
        let countBefore = applied.count
        composer.refreshHub()
        XCTAssertEqual(applied.count, countBefore)
    }
}
