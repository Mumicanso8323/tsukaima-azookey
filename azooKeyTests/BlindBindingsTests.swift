import Foundation
import XCTest
@testable import azooKey

final class BlindBindingsTests: XCTestCase {
    private func binding(_ action: BlindAction, _ hid: Int, _ style: BlindStyle = .double) -> BlindBinding {
        BlindBinding(action: action, hid: hid, style: style)
    }

    private func throwawayDefaults() -> (UserDefaults, String) {
        let name = "blind.bindings.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testConfigJSONMatchesProtocol() throws {
        var bindings = BlindBindings()
        bindings.set(binding(.toggle, 231, .double))
        bindings.set(binding(.read, 43, .hold))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bindings.configMessageData()) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "config")
        XCTAssertEqual(Set(object.keys), ["type", "bindings"])
        let list = try XCTUnwrap(object["bindings"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["action"] as? String, "toggle")
        XCTAssertEqual(list[0]["hid"] as? Int, 231)
        XCTAssertEqual(list[0]["style"] as? String, "double")
        XCTAssertEqual(Set(list[0].keys), ["action", "hid", "style"])
        XCTAssertEqual(list[1]["action"] as? String, "read")
        XCTAssertEqual(list[1]["style"] as? String, "hold")
    }

    func testSetReplacesAndOneKeyIsOneAction() {
        var bindings = BlindBindings()
        bindings.set(binding(.toggle, 10))
        bindings.set(binding(.toggle, 10, .hold))
        XCTAssertEqual(bindings.entries, [binding(.toggle, 10, .hold)])

        bindings.set(binding(.voice, 10, .tap))
        XCTAssertEqual(bindings.entries, [binding(.voice, 10, .tap)])

        bindings.set(binding(.voice, 11, .tap))
        XCTAssertEqual(bindings.count, 2)
        XCTAssertEqual(bindings.bindings(for: 11), [binding(.voice, 11, .tap)])
        XCTAssertTrue(bindings.bindings(for: 12).isEmpty)
    }

    func testRemove() {
        var bindings = BlindBindings()
        bindings.set(binding(.mode, 1))
        bindings.set(binding(.read, 2))
        bindings.remove(hid: 1)
        XCTAssertEqual(bindings.entries, [binding(.read, 2)])
        bindings.remove(hid: 99)
        XCTAssertEqual(bindings.count, 1)
    }

    func testCapsAtSixteenAndRejectsBadHid() {
        var bindings = BlindBindings()
        for hid in 0..<20 {
            bindings.set(binding(.toggle, hid))
        }
        XCTAssertEqual(bindings.count, 16)
        XCTAssertTrue(bindings.bindings(for: 16).isEmpty)
        // 満杯でも既存キーの付け替えはできる。
        XCTAssertTrue(bindings.set(binding(.read, 0, .tap)))
        XCTAssertEqual(bindings.count, 16)
        XCTAssertEqual(bindings.bindings(for: 0), [binding(.read, 0, .tap)])

        var empty = BlindBindings()
        XCTAssertFalse(empty.set(binding(.toggle, -1)))
        XCTAssertFalse(empty.set(binding(.toggle, 0x10000)))
        XCTAssertTrue(empty.isEmpty)
    }

    func testStoreRoundTrip() {
        let (defaults, name) = throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BlindBindingsStore(defaults: defaults)
        XCTAssertTrue(store.load().isEmpty)

        var bindings = BlindBindings()
        bindings.set(binding(.toggle, 231))
        bindings.set(binding(.voice, 0x8A, .tap))
        store.save(bindings)
        XCTAssertEqual(store.load(), bindings)
        XCTAssertNotNil(defaults.data(forKey: "blind.bindings.v1"))
    }

    func testCorruptedDataLoadsEmpty() {
        let (defaults, name) = throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not json".utf8), forKey: BlindBindingsStore.key)
        XCTAssertTrue(BlindBindingsStore(defaults: defaults).load().isEmpty)
        defaults.set(Data(#"{"entries":[{"action":"nope","hid":1,"style":"tap"}]}"#.utf8), forKey: BlindBindingsStore.key)
        XCTAssertTrue(BlindBindingsStore(defaults: defaults).load().isEmpty)
    }

    func testKeyNames() {
        XCTAssertEqual(BlindKeyNames.name(hid: 0xE7), "右Cmd")
        XCTAssertEqual(BlindKeyNames.name(hid: 0xE3), "左Cmd")
        XCTAssertEqual(BlindKeyNames.name(hid: 0xE6), "右Alt/Option")
        XCTAssertEqual(BlindKeyNames.name(hid: 0xE4), "右Ctrl")
        XCTAssertEqual(BlindKeyNames.name(hid: 0xE5), "右Shift")
        XCTAssertEqual(BlindKeyNames.name(hid: 0x39), "CapsLock")
        XCTAssertEqual(BlindKeyNames.name(hid: 0x35), "半角/全角")
        XCTAssertEqual(BlindKeyNames.name(hid: 0x8A), "変換")
        XCTAssertEqual(BlindKeyNames.name(hid: 0x8B), "無変換")
        XCTAssertEqual(BlindKeyNames.name(hid: 0x88), "カタカナひらがな")
        XCTAssertEqual(BlindKeyNames.name(hid: 0x3A), "F1")
        XCTAssertEqual(BlindKeyNames.name(hid: 0x45), "F12")
        XCTAssertEqual(BlindKeyNames.name(hid: 0x4B), "PageUp")
        XCTAssertEqual(BlindKeyNames.name(hid: 0x52), "↑")
        XCTAssertNil(BlindKeyNames.name(hid: 0x7FFF))
        XCTAssertNil(BlindKeyNames.name(hid: 0xF0))
        XCTAssertEqual(BlindKeyNames.label(hid: 0x7FFF, fallback: "keyboardX"), "keyboardX  hid 32767")
        XCTAssertEqual(BlindKeyNames.label(hid: 0xE7, fallback: "keyboardX"), "右Cmd  hid 231 (届いたまま)")
        XCTAssertEqual(BlindKeyNames.label(hid: 0xE0), "左Ctrl  hid 224 (届いたまま)")
        XCTAssertEqual(BlindKeyNames.label(hid: 0xE3), "左Cmd  hid 227 (届いたまま)")
        XCTAssertEqual(BlindKeyNames.label(hid: 0x39), "CapsLock  hid 57")
    }

    func testDiagnosticRowsAreDownOnlyDedupedNewestFirst() {
        let all = [
            BlindKeyDiagnostic(hid: 1, name: "a", down: true),
            BlindKeyDiagnostic(hid: 2, name: "b", down: true),
            BlindKeyDiagnostic(hid: 2, name: "b", down: false),
            BlindKeyDiagnostic(hid: 3, name: "c", down: false),
            BlindKeyDiagnostic(hid: 1, name: "a", down: true),
        ]
        XCTAssertEqual(BlindKeyDiagnostic.rows(all).map(\.hid), [1, 2])
    }
}
