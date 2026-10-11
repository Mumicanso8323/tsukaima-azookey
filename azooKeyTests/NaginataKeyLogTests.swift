import Foundation
import XCTest
@testable import azooKey

final class NaginataKeyLogTests: XCTestCase {
    func testLineIsJSONWithoutText() throws {
        let line = NaginataKeyLog.line(session: "abc", key: "w", down: true, t: 12.5)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["s"] as? String, "abc")
        XCTAssertEqual(obj["k"] as? String, "w")
        XCTAssertEqual(obj["d"] as? String, "down")
        XCTAssertEqual(obj["t"] as? Double, 12.5)
        XCTAssertEqual(obj.count, 4)
        XCTAssertFalse(line.contains("\n"))
    }

    func testSpaceAndUp() throws {
        let line = NaginataKeyLog.line(session: "s", key: " ", down: false, t: 1)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["k"] as? String, "space")
        XCTAssertEqual(obj["d"] as? String, "up")
    }

    func testAppendWritesOneLinePerCall() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("naginata-log-\(UUID().uuidString).jsonl")
        NaginataKeyLog.append("{\\"a\\":1}", to: url)
        NaginataKeyLog.append("{\\"a\\":2}", to: url)
        let done = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
        wait(for: [done], timeout: 3)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\\n").count, 2)
    }
}
