import AzooKeyUtils
import XCTest

final class NaginataPracticeTests: XCTestCase {
    func testAllSentencesAreTypeable() {
        for s in NaginataPractice.sentences {
            guard let tokens = NaginataPractice.tokens(for: s) else {
                XCTFail("表にない文字: \(s)")
                continue
            }
            XCTAssertEqual(tokens.map(\.text).joined(), s)
        }
        XCTAssertGreaterThanOrEqual(NaginataPractice.sentences.count, 20)
    }

    func testTokensAndKeys() {
        let tokens = NaginataPractice.tokens(for: "きゃざね、")
        XCTAssertEqual(tokens?.map(\.text), ["きゃ", "ざ", "ね", "、"])
        XCTAssertEqual(tokens?[0].keys, ["h", "w"])
        XCTAssertEqual(tokens?[1].keys, ["f", "u"])
        XCTAssertEqual(tokens?[2].keys, [" ", "w"])
        XCTAssertEqual(NaginataPractice.tokens(for: "ほ")?.first?.keys, ["z"])
        XCTAssertNil(NaginataPractice.tokens(for: "漢"))
    }

    func testRoles() {
        let single = NaginataPractice.roles(for: ["w"])
        XCTAssertEqual(single.base, ["w"])
        XCTAssertTrue(single.modifier.isEmpty)
        let voiced = NaginataPractice.roles(for: ["f", "u"])
        XCTAssertEqual(voiced.base, ["u"])
        XCTAssertEqual(voiced.modifier, ["f"])
        let thumb = NaginataPractice.roles(for: [" ", "w"])
        XCTAssertEqual(thumb.base, ["w"])
        XCTAssertEqual(thumb.modifier, [" "])
        let yoon = NaginataPractice.roles(for: ["j", "h", "w"])
        XCTAssertEqual(yoon.base, ["w"])
        XCTAssertEqual(yoon.modifier, ["j", "h"])
    }

    func testProgress() {
        var p = NaginataPracticeProgress(target: "ありがとう。")
        XCTAssertEqual(p.nextToken?.text, "あ")
        p.update(typed: "あり")
        XCTAssertEqual(p.matched, 2)
        XCTAssertEqual(p.nextToken?.text, "が")
        XCTAssertEqual(p.errors, 0)
        p.update(typed: "ありか")
        XCTAssertEqual(p.errors, 1)
        XCTAssertEqual(p.matched, 2)
        p.update(typed: "ありかか") // 外れたまま増やしても 1 回
        XCTAssertEqual(p.errors, 1)
        p.update(typed: "あり")
        p.update(typed: "ありが")
        XCTAssertEqual(p.errors, 1)
        p.update(typed: "ありがとう。")
        XCTAssertTrue(p.isComplete)
        XCTAssertNil(p.nextToken)
    }

    func testSpeedAndErrors() {
        var p = NaginataPracticeProgress(target: "いいね。") // 4 文字
        XCTAssertNil(p.charsPerMinute)
        p.update(typed: "", at: 5)
        XCTAssertNil(p.startedAt)
        p.update(typed: "い", at: 10)
        XCTAssertEqual(p.startedAt, 10)
        p.update(typed: "いか", at: 11)
        p.update(typed: "い", at: 12)
        p.update(typed: "いいね。", at: 14) // 4 秒で 4 文字 = 毎分 60
        XCTAssertEqual(p.errors, 1)
        XCTAssertEqual(p.finishedAt, 14)
        XCTAssertEqual(p.charsPerMinute ?? 0, 60, accuracy: 0.001)
        p.update(typed: "いいね。", at: 20) // 終了時刻は動かさない
        XCTAssertEqual(p.finishedAt, 14)
    }
}
