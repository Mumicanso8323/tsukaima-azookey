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
}
