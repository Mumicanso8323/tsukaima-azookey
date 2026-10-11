import AzooKeyUtils
import XCTest

final class NaginataEngineTests: XCTestCase {
    private func t(_ s: String) -> NaginataOutput { .text(s) }

    func testSingleStrokes() {
        let e = NaginataEngine()
        var out: [NaginataOutput] = []
        out += e.keyDown("w", at: 0)
        out += e.keyUp("w", at: 0.05)
        out += e.keyDown("e", at: 0.3)
        out += e.keyUp("e", at: 0.35)
        out += e.keyDown("j", at: 0.6)
        out += e.keyUp("j", at: 0.65)
        XCTAssertEqual(out, [t("き"), t("て"), t("あ")])
    }

    func testSimultaneousVoiced() {
        let e = NaginataEngine()
        _ = e.keyDown("f", at: 0)
        XCTAssertEqual(e.keyDown("u", at: 0.02), [t("ざ")])
        _ = e.keyUp("u", at: 0.1)
        _ = e.keyUp("f", at: 0.1)
        _ = e.keyDown("j", at: 1)
        var out = e.keyDown("w", at: 1.02)
        out += e.keyUp("w", at: 1.1)
        out += e.keyUp("j", at: 1.1)
        XCTAssertEqual(out, [t("ぎ")])
    }

    func testThumbShift() {
        let e = NaginataEngine()
        _ = e.keyDown(" ", at: 0)
        XCTAssertEqual(e.keyDown("w", at: 0.03), [t("ね")])
        XCTAssertEqual(e.keyUp("w", at: 0.1), [])
        XCTAssertEqual(e.keyUp(" ", at: 0.12), [])
    }

    func testSpaceAlone() {
        let e = NaginataEngine()
        _ = e.keyDown(" ", at: 0)
        XCTAssertEqual(e.keyUp(" ", at: 0.1), [.space])
    }

    func testYoon() {
        let e = NaginataEngine()
        _ = e.keyDown("h", at: 0)
        var out = e.keyDown("w", at: 0.02)
        out += e.keyUp("w", at: 0.1)
        out += e.keyUp("h", at: 0.1)
        XCTAssertEqual(out, [t("きゃ")])
    }

    func testContinuousShift() {
        let e = NaginataEngine()
        _ = e.keyDown("f", at: 0)
        var out = e.keyDown("u", at: 0.3)
        out += e.keyUp("u", at: 0.4)
        out += e.keyDown("o", at: 0.5)
        out += e.keyUp("o", at: 0.6)
        out += e.keyUp("f", at: 0.7)
        XCTAssertEqual(out, [t("ざ"), t("ず")])
    }

    func testOutsideWindowIsTwoKana() {
        let e = NaginataEngine()
        var out = e.keyDown("f", at: 0)
        out += e.keyUp("f", at: 0.03)
        out += e.keyDown("u", at: 0.5)
        out += e.keyUp("u", at: 0.55)
        XCTAssertEqual(out, [t("か")])
        // u 単独は表に無いので何も出ない
    }

    func testTimeoutFlush() {
        let e = NaginataEngine()
        XCTAssertEqual(e.keyDown("w", at: 0), [])
        XCTAssertEqual(e.nextDeadline(), 0.07)
        XCTAssertEqual(e.flush(at: 0.08), [t("き")])
        XCTAssertNil(e.nextDeadline())
    }

    func testSymbols() {
        func chord(_ keys: [Character]) -> [NaginataOutput] {
            let e = NaginataEngine()
            var out: [NaginataOutput] = []
            for (i, k) in keys.enumerated() { out += e.keyDown(k, at: Double(i) * 0.01) }
            for k in keys { out += e.keyUp(k, at: 0.2) }
            return out
        }
        XCTAssertEqual(chord(["j", "k", "d"]), [t("？")])
        XCTAssertEqual(chord(["j", "k", "f"]), [t("「")])
        XCTAssertEqual(chord(["j", "k", "v"]), [t("」")])
        XCTAssertEqual(chord([" ", "v"]), [t("、")])
        XCTAssertEqual(chord([" ", "m"]), [t("。")])
    }

    func testUnmatchedChordFallsBack() {
        let e = NaginataEngine()
        var out = e.keyDown("w", at: 0)
        out += e.keyDown("e", at: 0.01)
        out += e.flush(at: 0.2)
        XCTAssertEqual(out, [t("き"), t("て")])
    }
}
