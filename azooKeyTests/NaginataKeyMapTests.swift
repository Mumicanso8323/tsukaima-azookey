import XCTest
@testable import azooKey

final class NaginataKeyMapTests: XCTestCase {
    func testUsageMapping() {
        XCTAssertEqual(HardwareIMETextView.naginataKey(usage: 0x04, hasModifier: false), "a")
        XCTAssertEqual(HardwareIMETextView.naginataKey(usage: 0x1D, hasModifier: false), "z")
        XCTAssertEqual(HardwareIMETextView.naginataKey(usage: 0x1A, hasModifier: false), "w")
        XCTAssertEqual(HardwareIMETextView.naginataKey(usage: 0x2C, hasModifier: false), " ")
        XCTAssertEqual(HardwareIMETextView.naginataKey(usage: 0x33, hasModifier: false), ";")
        XCTAssertEqual(HardwareIMETextView.naginataKey(usage: 0x36, hasModifier: false), ",")
        XCTAssertEqual(HardwareIMETextView.naginataKey(usage: 0x37, hasModifier: false), ".")
        XCTAssertEqual(HardwareIMETextView.naginataKey(usage: 0x38, hasModifier: false), "/")
    }

    func testNonNaginataAndModifiers() {
        XCTAssertNil(HardwareIMETextView.naginataKey(usage: 0x28, hasModifier: false)) // Return
        XCTAssertNil(HardwareIMETextView.naginataKey(usage: 0x2A, hasModifier: false)) // Backspace
        XCTAssertNil(HardwareIMETextView.naginataKey(usage: 0x04, hasModifier: true))
        XCTAssertNil(HardwareIMETextView.naginataKey(usage: 0x1E, hasModifier: false)) // 1
    }
}
