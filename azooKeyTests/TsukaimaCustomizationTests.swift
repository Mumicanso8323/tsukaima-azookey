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
        XCTAssertEqual(elements.map { $0.value() }, [TsukaimaDictionaryLayer.hubValue, TsukaimaDictionaryLayer.hubValue, TsukaimaDictionaryLayer.hubValue])
    }

    // MARK: - 定型文は候補に出るだけ(自動置換しない)

    /// hint「定型文」の語は普通の語より弱い重みになり、先頭候補・ライブ変換で勝手に本文へ置き換わらない
    func testSnippetIsWeakCandidateNotReplacement() throws {
        let payload = TsukaimaImeDict.Payload(words: [
            .init(word: "よろしくお願いいたします。", reading: "よろしく", hint: "定型文"),
            .init(word: "文理祭", reading: "ぶんりさい", hint: "固有名詞"),
        ])
        let elements = TsukaimaDictionaryLayer.elements(payload)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0].value(), TsukaimaDictionaryLayer.snippetValue)
        XCTAssertEqual(elements[1].value(), TsukaimaDictionaryLayer.hubValue)
        XCTAssertLessThan(TsukaimaDictionaryLayer.snippetValue, TsukaimaDictionaryLayer.trpgValue)
        XCTAssertLessThan(TsukaimaDictionaryLayer.trpgValue, TsukaimaDictionaryLayer.hubValue)
        // 変換器に混ぜる前提の要素であること(cid は一般名詞・読みはカタカナ)
        XCTAssertEqual(elements[0].ruby, "ヨロシク")
        XCTAssertEqual(elements[0].lcid, CIDData.一般名詞.cid)
    }

    // MARK: - 同梱 TRPG 語彙

    func testTrpgDictionaryIsWellFormed() {
        let words = TsukaimaTrpgDict.words
        XCTAssertGreaterThan(words.count, 500)
        let hiragana = CharacterSet(charactersIn: Unicode.Scalar(0x3041)!...Unicode.Scalar(0x3096)!).union(CharacterSet(charactersIn: "ー"))
        for w in words {
            XCTAssertFalse(w.word.isEmpty, "empty word for \(w.reading)")
            XCTAssertFalse(w.reading.isEmpty, "empty reading for \(w.word)")
            XCTAssertTrue(w.reading.unicodeScalars.allSatisfy { hiragana.contains($0) }, "reading must be hiragana: \(w.reading)")
        }
        // 同じ(読み, 表記)の重複は build() で落ちている
        XCTAssertEqual(Set(words.map { $0.reading + "\t" + $0.word }).count, words.count)
        XCTAssertTrue(words.contains { $0.reading == "くとぅるふ" && $0.word == "クトゥルフ" })
        XCTAssertTrue(words.contains { $0.reading == "さんち" && $0.word == "SAN値" })
        XCTAssertTrue(words.contains { $0.reading == "ねくろまんさー" && $0.word == "ネクロマンサー" })
    }

    func testCombinedElementsPrefersHubOverBundled() {
        let payload = TsukaimaImeDict.Payload(words: [.init(word: "クトゥルフ", reading: "くとぅるふ", hint: "固有名詞")])
        let elements = TsukaimaDictionaryLayer.combinedElements(hub: payload)
        let cthulhu = elements.filter { $0.word == "クトゥルフ" && $0.ruby == "クトゥルフ" }
        XCTAssertEqual(cthulhu.count, 1)
        XCTAssertEqual(cthulhu.first?.value(), TsukaimaDictionaryLayer.hubValue)
        XCTAssertGreaterThan(elements.count, 500)
        // hub が無いときは同梱語彙だけ
        XCTAssertEqual(TsukaimaDictionaryLayer.combinedElements(hub: nil).count, TsukaimaDictionaryLayer.trpgElements().count)
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
        // hub 辞書がまだ無くても、同梱の TRPG 語彙は最初から乗っている
        XCTAssertEqual(applied.last?.contains("クトゥルフ"), true)
        XCTAssertEqual(applied.last?.contains("使い魔"), false)

        // 本体アプリが TsukaimaAPI.shared で取得して書くのと同じ経路
        let payload = TsukaimaImeDict.Payload(words: [.init(word: "使い魔", reading: "つかいま")])
        TsukaimaImeDict.write(try JSONEncoder().encode(payload), base: base)

        composer.refreshHub()
        XCTAssertEqual(applied.last?.first, "使い魔") // hub の語が先、その後ろに同梱語彙
        XCTAssertEqual(applied.last?.contains("クトゥルフ"), true)

        // mtime が変わっていなければ何もしない(キーボードは表示のたびに呼ぶため)
        let countBefore = applied.count
        composer.refreshHub()
        XCTAssertEqual(applied.count, countBefore)
    }
}
