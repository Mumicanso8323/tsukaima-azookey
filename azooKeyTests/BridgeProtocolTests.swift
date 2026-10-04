import Foundation
import XCTest
@testable import azooKey

final class BridgeProtocolTests: XCTestCase {
    func testKeysPacketDecode() throws {
        let packet = try XCTUnwrap(KeysPacket(data: Data([0x34, 0x12, 0xE7, 0x00, 0x01, 0x05])))
        XCTAssertEqual(packet.seq, 0x1234)
        XCTAssertEqual(packet.hid, 231)
        XCTAssertTrue(packet.down)
        XCTAssertEqual(packet.mods, 5)
        let up = try XCTUnwrap(KeysPacket(data: Data([0xFF, 0xFF, 0x2B, 0x01, 0x00, 0x00])))
        XCTAssertEqual(up.seq, 0xFFFF)
        XCTAssertEqual(up.hid, 0x012B)
        XCTAssertFalse(up.down)
    }

    func testKeysPacketRejectsWrongLength() {
        XCTAssertNil(KeysPacket(data: Data()))
        XCTAssertNil(KeysPacket(data: Data([1, 0, 2, 0, 1])))
        XCTAssertNil(KeysPacket(data: Data([1, 0, 2, 0, 1, 0, 0])))
    }

    func testKeysPacketDecodesFromSlice() throws {
        let base = Data([9, 9, 0x01, 0x00, 0x04, 0x00, 0x01, 0x00, 9])
        let packet = try XCTUnwrap(KeysPacket(data: base[2..<8]))
        XCTAssertEqual(packet.seq, 1)
        XCTAssertEqual(packet.hid, 4)
    }

    func testModePacketDecode() throws {
        let packet = try XCTUnwrap(ModePacket(data: Data([1, 0, 3, 87, 0x02, 0x01])))
        XCTAssertTrue(packet.blind)
        XCTAssertFalse(packet.hidGate)
        XCTAssertEqual(packet.kbState, .ready)
        XCTAssertEqual(packet.battery, 87)
        XCTAssertEqual(packet.seq, 0x0102)
        let unknown = try XCTUnwrap(ModePacket(data: Data([0, 1, 200, 0xFF, 0, 0])))
        XCTAssertNil(unknown.battery)
        XCTAssertEqual(unknown.kbState, .boot)
    }

    func testModePacketRejectsWrongLength() {
        XCTAssertNil(ModePacket(data: Data([1, 0, 5, 87, 2])))
        XCTAssertNil(ModePacket(data: Data([1, 0, 5, 87, 2, 1, 0])))
        XCTAssertNil(ModePacket(data: Data()))
    }

    func testConfigGoldenBytes() {
        let bindings = [
            BlindBinding(action: .toggle, hid: 231, style: .double),
            BlindBinding(action: .read, hid: 43, style: .hold),
        ]
        XCTAssertEqual(
            [UInt8](ControlPacket.config(bindings).encode()),
            [0x01, 0x02, 0x01, 0xE7, 0x00, 0x01, 0x04, 0x2B, 0x00, 0x02]
        )
        let wide = [BlindBinding(action: .voice, hid: 0x1234, style: .tap), BlindBinding(action: .mode, hid: 1, style: .tap)]
        XCTAssertEqual(
            [UInt8](ControlPacket.config(wide).encode()),
            [0x01, 0x02, 0x03, 0x34, 0x12, 0x03, 0x02, 0x01, 0x00, 0x03]
        )
    }

    func testConfigEmptyAndTruncation() {
        XCTAssertEqual([UInt8](ControlPacket.config([]).encode()), [0x01, 0x00])
        let many = (0..<20).map { BlindBinding(action: .toggle, hid: $0, style: .tap) }
        let bytes = [UInt8](ControlPacket.config(many).encode())
        XCTAssertEqual(bytes[1], 16)
        XCTAssertEqual(bytes.count, 2 + 16 * 4)
    }

    func testHidGateAndPing() {
        XCTAssertEqual([UInt8](ControlPacket.hidGate(true).encode()), [0x02, 0x01])
        XCTAssertEqual([UInt8](ControlPacket.hidGate(false).encode()), [0x02, 0x00])
        XCTAssertEqual([UInt8](ControlPacket.ping.encode()), [0x03])
    }

    func testSeqTracker() {
        var tracker = SeqTracker()
        XCTAssertEqual(tracker.observe(10), .first)
        XCTAssertEqual(tracker.observe(11), .inOrder)
        XCTAssertEqual(tracker.observe(15), .gap(missed: 3))
        XCTAssertEqual(tracker.totalMissed, 3)
        XCTAssertEqual(tracker.observe(15), .duplicate)
        XCTAssertEqual(tracker.observe(12), .stale)
        XCTAssertEqual(tracker.last, 15)
        XCTAssertEqual(tracker.observe(16), .inOrder)
        XCTAssertEqual(tracker.totalMissed, 3)
    }

    func testSeqTrackerWrap() {
        var tracker = SeqTracker()
        XCTAssertEqual(tracker.observe(65534), .first)
        XCTAssertEqual(tracker.observe(65535), .inOrder)
        XCTAssertEqual(tracker.observe(0), .inOrder)
        XCTAssertEqual(tracker.observe(2), .gap(missed: 1))
        var skipping = SeqTracker()
        _ = skipping.observe(65535)
        XCTAssertEqual(skipping.observe(2), .gap(missed: 2))
    }

    func testKbStateLabels() {
        XCTAssertEqual(BridgeKbState(raw: 3).label, "使える")
        XCTAssertEqual(BridgeKbState(raw: 99), .boot)
        // protocol.h の bridge_kb_state(確定値)
        let expected: [(UInt8, BridgeKbState)] = [
            (0, .boot), (1, .scanning), (2, .connecting), (3, .ready), (4, .disconnected),
            (5, .probeBleFound), (6, .probeClassicOnly), (7, .probeNotFound),
        ]
        for (raw, state) in expected { XCTAssertEqual(BridgeKbState(raw: raw), state) }
        XCTAssertEqual(BridgeKbState.allCases.count, 8)
        XCTAssertEqual(BridgeKbState.allCases.filter(\.isProbe).count, 3)
        XCTAssertNil(BridgeKbState.ready.probeResult)
        XCTAssertEqual(BridgeKbState.probeBleFound.probeResult, "判定結果: このキーボードは BLE です")
        for state in BridgeKbState.allCases {
            XCTAssertFalse(state.label.isEmpty)
        }
        XCTAssertEqual(Set(BridgeKbState.allCases.map(\.label)).count, BridgeKbState.allCases.count)
    }

    func testLogLineAndLockSummary() {
        let records = [
            BridgePacketRecord(id: 0, seq: 1, down: true, appState: .active, deltaMs: nil, missedBefore: 0, cue: .notApplicable),
            BridgePacketRecord(id: 1, seq: 2, down: false, appState: .background, deltaMs: 100, missedBefore: 0, cue: .ok),
            BridgePacketRecord(id: 2, seq: 5, down: true, appState: .inactive, deltaMs: 300, missedBefore: 2, cue: .skipped),
        ]
        XCTAssertEqual(records[1].logLine(iso: "T"), "T seq=2 down=0 app=background delta_ms=100 missed=0 cue=ok")
        XCTAssertFalse(records[0].logLine(iso: "T").contains("hid"))
        let summary = BridgeLockSummary(records: records)
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.maxDeltaMs, 300)
        XCTAssertEqual(summary.averageDeltaMs, 200)
        XCTAssertEqual(summary.missed, 2)
        XCTAssertEqual(summary.cueOK, 1)
        XCTAssertEqual(summary.cueSkipped, 1)
        XCTAssertEqual(summary.cueFail, 0)
    }

    func testPinPolicy() {
        let a = UUID()
        let b = UUID()
        XCTAssertEqual(BridgePinPolicy.decide(pinned: nil, candidate: a), .listOnly)
        XCTAssertEqual(BridgePinPolicy.decide(pinned: a, candidate: a), .connect)
        XCTAssertEqual(BridgePinPolicy.decide(pinned: a, candidate: b), .ignore)
    }

    func testRateLimiter() {
        var limiter = BridgeRateLimiter(limit: 3)
        XCTAssertEqual(limiter.check(at: 10.0), .accept)
        XCTAssertEqual(limiter.check(at: 10.1), .accept)
        XCTAssertEqual(limiter.check(at: 10.2), .accept)
        XCTAssertEqual(limiter.check(at: 10.3), .dropFirst)
        XCTAssertEqual(limiter.check(at: 10.4), .drop)
        XCTAssertEqual(limiter.totalDropped, 2)
        // 次の秒に入ると、また受ける。
        XCTAssertEqual(limiter.check(at: 11.0), .accept)
        XCTAssertEqual(limiter.totalDropped, 2)
    }

    func testBatteryOutOfRangeIsUnknown() throws {
        let packet = try XCTUnwrap(ModePacket(data: Data([0, 0, 5, 150, 0, 0])))
        XCTAssertNil(packet.battery)
        XCTAssertEqual(try XCTUnwrap(ModePacket(data: Data([0, 0, 5, 100, 0, 0]))).battery, 100)
    }

    func testDiscoveredShortID() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        XCTAssertEqual(BridgeDiscovered(id: id, name: "x", rssi: -50).shortID, "9ABC")
    }

    func testDeliveryDecision() {
        let pin = UUID()
        let other = UUID()
        let service = BridgeGATT.serviceUUID
        let keys = BridgeGATT.keysUUID
        let subscribed: Set<String> = [keys, BridgeGATT.modeUUID]
        // 一致・購読済み・正しいサービス
        XCTAssertEqual(BridgePinPolicy.decideDelivery(pinned: pin, peripheral: pin, service: service, characteristic: keys, subscribed: subscribed), .deliver)
        // 大文字小文字の違いは同じ UUID
        XCTAssertEqual(BridgePinPolicy.decideDelivery(pinned: pin, peripheral: pin, service: service.lowercased(), characteristic: keys.lowercased(), subscribed: subscribed), .deliver)
        // 固定なし(解除後・読み出し失敗も nil)は、切断
        XCTAssertEqual(BridgePinPolicy.decideDelivery(pinned: nil, peripheral: pin, service: service, characteristic: keys, subscribed: subscribed), .disconnect)
        // 不一致(別の機器に固定が変わった)は、切断
        XCTAssertEqual(BridgePinPolicy.decideDelivery(pinned: other, peripheral: pin, service: service, characteristic: keys, subscribed: subscribed), .disconnect)
        // 未購読の特性
        XCTAssertEqual(BridgePinPolicy.decideDelivery(pinned: pin, peripheral: pin, service: service, characteristic: keys, subscribed: [BridgeGATT.modeUUID]), .drop)
        XCTAssertEqual(BridgePinPolicy.decideDelivery(pinned: pin, peripheral: pin, service: service, characteristic: keys, subscribed: []), .drop)
        // 別のサービス・サービス不明
        XCTAssertEqual(BridgePinPolicy.decideDelivery(pinned: pin, peripheral: pin, service: "7A5E9999-B11D-4C0F-9A2E-5B7D00000001", characteristic: keys, subscribed: subscribed), .drop)
        XCTAssertEqual(BridgePinPolicy.decideDelivery(pinned: pin, peripheral: pin, service: nil, characteristic: keys, subscribed: subscribed), .drop)
        // 別の特性(購読集合に無い UUID)
        XCTAssertEqual(BridgePinPolicy.decideDelivery(pinned: pin, peripheral: pin, service: service, characteristic: "7A5E0099-B11D-4C0F-9A2E-5B7D00000001", subscribed: subscribed), .drop)
    }

    /// firmware/esp32-blind-bridge/core/protocol.h の文字列のコピー。ファームの UUID を変えたら、ここも変えないと落ちる。
    func testGATTUUIDsMatchFirmwareProtocolHeader() {
        XCTAssertEqual(BridgeGATT.serviceUUID, "7d4e9bb1-21c2-4b3f-9f16-6f0e7b9a4101")
        XCTAssertEqual(BridgeGATT.keysUUID, "7d4e9bb2-21c2-4b3f-9f16-6f0e7b9a4101")
        XCTAssertEqual(BridgeGATT.controlUUID, "7d4e9bb3-21c2-4b3f-9f16-6f0e7b9a4101")
        XCTAssertEqual(BridgeGATT.modeUUID, "7d4e9bb4-21c2-4b3f-9f16-6f0e7b9a4101")
        for text in [BridgeGATT.serviceUUID, BridgeGATT.keysUUID, BridgeGATT.controlUUID, BridgeGATT.modeUUID] {
            XCTAssertNotNil(UUID(uuidString: text))
        }
    }

    func testControlOpcodesMatchFirmware() {
        XCTAssertEqual([UInt8](ControlPacket.clearBonds.encode()), [0x04])
        XCTAssertEqual(ControlPacket.opConfig, 0x01)
        XCTAssertEqual(ControlPacket.opHidGate, 0x02)
        XCTAssertEqual(ControlPacket.opPing, 0x03)
        XCTAssertEqual(ControlPacket.opClearBonds, 0x04)
    }
}
