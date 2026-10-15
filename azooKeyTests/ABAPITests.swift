//
//  ABAPITests.swift
//  A/B テストの API 応答の寛容な解析(ABAPI)のテスト
//

import Foundation
import XCTest
@testable import azooKey

final class ABAPITests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testPrimaryShape() throws {
        let s = try ABAPI.parseNext(data(#"{"done":false,"round":"r1","pair":{"id":"p3","a":"/api/ab/img/r1/x","b":"/api/ab/img/r1/y"},"index":3,"total":24}"#))
        XCTAssertFalse(s.done)
        XCTAssertEqual(s.pair, ABAPI.Pair(id: "p3", a: "/api/ab/img/r1/x", b: "/api/ab/img/r1/y"))
        XCTAssertEqual(s.position, 3)
        XCTAssertEqual(s.total, 24)
    }

    func testAlternativeKeySpellings() throws {
        let s1 = try ABAPI.parseNext(data(#"{"pair":{"pair_id":7,"a_url":"https://e/a.png","b_url":"https://e/b.png"},"progress":{"answered":4,"total":10}}"#))
        XCTAssertEqual(s1.pair, ABAPI.Pair(id: "7", a: "https://e/a.png", b: "https://e/b.png"))
        XCTAssertEqual(s1.position, 5)
        XCTAssertEqual(s1.total, 10)
        let s2 = try ABAPI.parseNext(data(#"{"done":false,"pair":{"id":"q","image_a":"/a","image_b":"/b"},"index":1,"total":2}"#))
        XCTAssertEqual(s2.pair, ABAPI.Pair(id: "q", a: "/a", b: "/b"))
    }

    func testDone() throws {
        let s = try ABAPI.parseNext(data(#"{"done":true}"#))
        XCTAssertTrue(s.done)
        XCTAssertNil(s.pair)
    }

    func testVoteResponseWithNext() throws {
        let s = try ABAPI.parseVote(data(#"{"done":false,"next":{"done":false,"pair":{"id":"p4","a":"/a","b":"/b"},"index":4,"total":24}}"#))
        XCTAssertFalse(s.done)
        XCTAssertEqual(s.pair?.id, "p4")
        XCTAssertEqual(s.position, 4)
        let bare = try ABAPI.parseVote(data(#"{"done":false,"next":{"id":"p5","a":"/a","b":"/b"},"index":5,"total":24}"#))
        XCTAssertEqual(bare.pair?.id, "p5")
        XCTAssertEqual(bare.position, 5)
        let fin = try ABAPI.parseVote(data(#"{"done":true,"next":null}"#))
        XCTAssertTrue(fin.done)
        let missing = try ABAPI.parseVote(data(#"{"ok":true}"#))
        XCTAssertFalse(missing.done)
        XCTAssertNil(missing.pair)
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try ABAPI.parseNext(data("not json")))
    }
}
