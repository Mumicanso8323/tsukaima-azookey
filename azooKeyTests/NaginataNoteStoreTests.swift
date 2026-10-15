import Foundation
import XCTest
@testable import azooKey

final class NaginataNoteStoreTests: XCTestCase {
    private func makeStore() -> NaginataNoteStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("naginata-test-\(UUID().uuidString)")
        return NaginataNoteStore(directory: dir)
    }

    func testRoundTrip() throws {
        let store = makeStore()
        try store.save("これはテスト。")
        XCTAssertEqual(store.load(), "これはテスト。")
    }

    func testEmptyAndMissing() throws {
        let store = makeStore()
        XCTAssertEqual(store.load(), "")
        try store.save("")
        XCTAssertEqual(store.load(), "")
    }

    func testNewlinesAndEmoji() throws {
        let store = makeStore()
        let text = "一行目\n\n三行目 😀👨‍👩‍👧\n"
        try store.save(text)
        XCTAssertEqual(store.load(), text)
        XCTAssertEqual(store.fileURL().lastPathComponent, "note-1.txt")
    }

    func testOverwrite() throws {
        let store = makeStore()
        try store.save("a")
        try store.save("b")
        XCTAssertEqual(store.load(), "b")
    }

    func testLegacySingleNoteIsFirst() throws {
        let store = makeStore()
        try store.save("旧版のメモ") // index.json なし = 旧版の note-1.txt
        let idx = store.index()
        XCTAssertEqual(idx.ids, [1])
        XCTAssertEqual(idx.current, 1)
        XCTAssertEqual(store.load(id: 1), "旧版のメモ")
        XCTAssertEqual(store.title(id: 1), "旧版のメモ")
    }

    func testCreateSwitchDelete() throws {
        let store = makeStore()
        try store.save("一枚目\n続き")
        let second = try store.create()
        XCTAssertEqual(second, 2)
        XCTAssertEqual(store.index().ids, [1, 2])
        XCTAssertEqual(store.index().current, 2)
        XCTAssertEqual(store.load(id: 2), "")
        XCTAssertEqual(store.title(id: 2), "(空のメモ)")
        try store.save("二枚目", id: 2)
        XCTAssertEqual(store.load(id: 1), "一枚目\n続き")
        XCTAssertEqual(store.title(id: 1), "一枚目")
        try store.setCurrent(1)
        XCTAssertEqual(store.index().current, 1)
        try store.delete(1)
        XCTAssertEqual(store.index().ids, [2])
        XCTAssertEqual(store.index().current, 2)
        XCTAssertEqual(store.load(id: 1), "")
        // id は使い回さない
        XCTAssertEqual(try store.create(), 3)
    }

    func testDeleteLastLeavesOneEmptyNote() throws {
        let store = makeStore()
        try store.save("だけ")
        try store.delete(1)
        let idx = store.index()
        XCTAssertEqual(idx.ids.count, 1)
        XCTAssertEqual(store.load(id: idx.ids[0]), "")
        XCTAssertNotEqual(idx.ids[0], 1)
    }
}
