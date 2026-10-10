import Foundation
import XCTest
@testable import azooKey

final class BlindKeysTests: XCTestCase {
    private func event(_ hid: Int, t: Double = 100, down: Bool = true) -> BlindKeyEvent {
        BlindKeyEvent(hid: hid, down: down, t: t, char: hid == 4 ? "a" : nil)
    }

    func testQueueDropsExpiredEventsOnAppendAndDrain() {
        var queue = BlindKeyQueue()
        queue.append(event(1, t: 39), now: 100)
        queue.append(event(2, t: 40), now: 100)
        queue.append(event(3, t: 100), now: 100)
        XCTAssertEqual(queue.drain(now: 100).map(\.hid), [2, 3])

        queue.append(event(4, t: 100), now: 100)
        XCTAssertTrue(queue.drain(now: 161).isEmpty)
    }

    func testQueueRemovesAnExpiredEventEvenWhenItIsNotAtTheHead() {
        var queue = BlindKeyQueue()
        queue.append(event(1, t: 100), now: 100)
        queue.append(event(2, t: 40), now: 100)
        XCTAssertEqual(queue.drain(now: 101).map(\.hid), [1])
    }

    func testQueueKeepsNewestFiveHundredInOrder() {
        var queue = BlindKeyQueue()
        for hid in 0...500 {
            queue.append(event(hid), now: 100)
        }
        let events = queue.drain(now: 100)
        XCTAssertEqual(events.count, BlindKeyQueue.maximumEvents)
        XCTAssertEqual(events.first?.hid, 1)
        XCTAssertEqual(events.last?.hid, 500)
    }

    func testQueueBatchesAtTwoHundredWithoutChangingOrder() {
        var queue = BlindKeyQueue()
        for hid in 0..<401 {
            queue.append(event(hid), now: 100)
        }
        let batches = queue.batches(now: 100)
        XCTAssertEqual(batches.map(\.count), [200, 200, 1])
        XCTAssertEqual(batches.flatMap { $0 }.map(\.hid), Array(0..<401))
        XCTAssertEqual(queue.count, 0)
    }

    func testKeyEventEncodesProtocolJSONShape() throws {
        let data = try JSONEncoder().encode(BlindKeyEvent(hid: 228, down: true, t: 123.456, char: nil))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["hid"] as? Int, 228)
        XCTAssertEqual(object["down"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(object["t"] as? Double), 123.456, accuracy: 0.000_001)
        XCTAssertTrue(object["char"] is NSNull)
    }

    func testBeepToneTableAndRawValues() {
        XCTAssertEqual(BlindBeep.sent.rawValue, "sent")
        XCTAssertEqual(BlindBeep.noListener.rawValue, "no_listener")
        XCTAssertEqual(BlindBeep.voiceOn.rawValue, "voice_on")
        XCTAssertEqual(BlindBeep.readNone.rawValue, "read_none")
        XCTAssertEqual(BlindBeep.enter.tones.map(\.freq), [660, 990])
        XCTAssertEqual(BlindBeep.enter.tones.map(\.ms), [90, 120])
        XCTAssertEqual(BlindBeep.exit.tones.map(\.freq), [990, 660])
        XCTAssertEqual(BlindBeep.noListener.tones.map(\.ms), [110, 110, 110])
        XCTAssertEqual(BlindBeep.readNone.tones.map(\.freq), [500, 500])
    }

    func testUnknownBeepIsIgnored() {
        XCTAssertNil(BlindBeep(rawValue: "unexpected"))
        XCTAssertNil(BlindLink.beep(named: "unexpected"))
        XCTAssertEqual(BlindLink.beep(named: "sent"), .sent)
    }

    func testWakePolicyKeepsAwakeDuringGraceThenSleeps() {
        let policy = BlindWakePolicy(openedAt: 100, grace: 300)
        XCTAssertTrue(policy.keepAwake(now: 100))
        XCTAssertTrue(policy.keepAwake(now: 399))
        XCTAssertFalse(policy.keepAwake(now: 400))
    }

    func testWakePolicyStaysAwakeWhileBlindOnAndReleasesRightAfterExit() {
        var policy = BlindWakePolicy(openedAt: 100, grace: 300)
        policy.update(blindOn: true)
        XCTAssertTrue(policy.keepAwake(now: 5_000))
        // 自動脱出・Esc 長押しで出た: 猶予が残っていても普通に消える設定へ戻す
        policy.update(blindOn: false)
        XCTAssertFalse(policy.keepAwake(now: 5_001))
        XCTAssertFalse(policy.keepAwake(now: 120))
    }

    func testWakePolicyBlindOffBeforeEverOnKeepsTheGrace() {
        var policy = BlindWakePolicy(openedAt: 100, grace: 300)
        policy.update(blindOn: false)
        XCTAssertTrue(policy.keepAwake(now: 200))
    }
}
