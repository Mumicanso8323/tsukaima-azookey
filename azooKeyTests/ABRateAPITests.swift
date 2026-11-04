//
//  ABRateAPITests.swift
//  1--10 採点 API 応答の寛容な解析(ABRateAPI)のテスト
//

import Foundation
import XCTest
@testable import azooKey

final class ABRateAPITests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testPrimaryShape() throws {
        let status = try ABRateAPI.parseNext(data(#"{"done":false,"round":"r1","item":{"id":"i3","image":"/api/ab/img/r1/x"},"index":3,"total":72,"scale":{"min":1,"max":10,"low":"全然ダメ","high":"最高"}}"#))
        XCTAssertFalse(status.done)
        XCTAssertEqual(status.item, ABRateAPI.Item(id: "i3", image: "/api/ab/img/r1/x"))
        XCTAssertEqual(status.position, 3)
        XCTAssertEqual(status.total, 72)
        XCTAssertEqual(status.scale, ABRateAPI.Scale(min: 1, max: 10, low: "全然ダメ", high: "最高"))
    }

    func testAlternativeKeySpellings() throws {
        let status = try ABRateAPI.parseNext(data(#"{"item":{"item_id":7,"url":{"url":"https://example.test/a.webp"}},"progress":{"answered":4,"total":"10"},"scale":{"min":"1","max":10,"low":"低","high":"高"}}"#))
        XCTAssertEqual(status.item, ABRateAPI.Item(id: "7", image: "https://example.test/a.webp"))
        XCTAssertEqual(status.position, 5)
        XCTAssertEqual(status.total, 10)
    }

    func testDone() throws {
        let status = try ABRateAPI.parseNext(data(#"{"done":true}"#))
        XCTAssertTrue(status.done)
        XCTAssertNil(status.item)
    }

    func testVoteResponseWithNullAndNext() throws {
        let nullNext = try ABRateAPI.parseVote(data(#"{"done":true,"next":null,"round_complete":true,"notified":true}"#))
        XCTAssertTrue(nullNext.done)
        XCTAssertTrue(nullNext.nextProvided)
        XCTAssertNil(nullNext.next)
        XCTAssertTrue(nullNext.roundComplete)
        XCTAssertTrue(nullNext.notified)

        let next = try ABRateAPI.parseVote(data(#"{"done":false,"next":{"done":false,"item":{"id":"i4","image":"/next.webp"},"index":4,"total":72,"scale":{"min":1,"max":10,"low":"全然ダメ","high":"最高"}}}"#))
        XCTAssertFalse(next.done)
        XCTAssertTrue(next.nextProvided)
        XCTAssertEqual(next.next?.item, ABRateAPI.Item(id: "i4", image: "/next.webp"))
        XCTAssertEqual(next.next?.position, 4)
    }
}
