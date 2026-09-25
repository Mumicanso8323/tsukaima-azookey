//
//  AppGroupResolutionTests.swift
//  使い魔azooKey: SideStore が書き換えた App Group ID の解決
//

@testable import AzooKeyUtils
import XCTest

final class AppGroupResolutionTests: XCTestCase {
    func testDefaultWhenNoAltAppGroups() {
        XCTAssertEqual(SharedStore.resolveAppGroupKey(altAppGroups: nil), SharedStore.defaultAppGroupKey)
        XCTAssertEqual(SharedStore.resolveAppGroupKey(altAppGroups: []), SharedStore.defaultAppGroupKey)
        XCTAssertEqual(SharedStore.resolveAppGroupKey(altAppGroups: [""]), SharedStore.defaultAppGroupKey)
    }

    func testPrefersRewrittenGroupWithOurPrefix() {
        let rewritten = SharedStore.defaultAppGroupKey + ".ABCDE12345"
        XCTAssertEqual(SharedStore.resolveAppGroupKey(altAppGroups: ["group.other", rewritten]), rewritten)
    }

    func testFallsBackToFirstGroup() {
        XCTAssertEqual(SharedStore.resolveAppGroupKey(altAppGroups: ["group.other"]), "group.other")
    }
}
