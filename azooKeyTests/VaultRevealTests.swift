//
//  VaultRevealTests.swift
//  保管庫の「Face ID で値を表示」まわりの純粋な部分(応答の解析・クリップボードの設定・伏せ字)。値はすべて偽物。
//

import Foundation
import UIKit
import XCTest
@testable import azooKey

@MainActor
final class VaultRevealTests: XCTestCase {
    func testDecodeWithTotp() throws {
        let json: [String: Any] = ["site": "s", "login": "u@example.invalid", "password": "FAKE", "totp": "123456", "totp_left": 12]
        let s = try CSNet.decode(json, as: SettingsVaultSecret.self)
        XCTAssertEqual(s, SettingsVaultSecret(site: "s", login: "u@example.invalid", password: "FAKE", totp: "123456", totpLeft: 12))
    }

    func testDecodeWithoutTotp() throws {
        let s = try CSNet.decode(["site": "fanatical", "login": "", "password": "FAKE"] as [String: Any], as: SettingsVaultSecret.self)
        XCTAssertNil(s.totp)
        XCTAssertNil(s.totpLeft)
    }

    func testClipboardOptionsAreLocalOnlyAndExpireIn60Seconds() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let o = VaultClipboard.options(now: now)
        XCTAssertEqual(o[.localOnly] as? Bool, true)
        XCTAssertEqual(o[.expirationDate] as? Date, now.addingTimeInterval(60))
        XCTAssertEqual(VaultClipboard.expireSeconds, 60)
    }

    func testCopyPutsValueOnPasteboard() {
        VaultClipboard.copy("FAKE-copy-value")
        XCTAssertEqual(UIPasteboard.general.string, "FAKE-copy-value")
        UIPasteboard.general.string = ""
    }

    func testMaskHidesLength() {
        XCTAssertEqual(VaultMask.text.count, 8)
        XCTAssertFalse(VaultMask.text.contains("a"))
    }

    func testDecodeHistoryAndDeleted() throws {
        let json: [String: Any] = ["site": "Google", "login": "a", "password": "NEW",
                                   "history": [["at": 1_790_000_000, "password": "OLD1"], ["at": 1_789_000_000, "login": "o@example.invalid", "totp": "JBSWY3DP"]],
                                   "deleted_at": 1_790_100_000]
        let s = try CSNet.decode(json, as: SettingsVaultSecret.self)
        XCTAssertEqual(s.history?.count, 2)
        XCTAssertEqual(s.history?[0], SettingsVaultHistoryEntry(at: 1_790_000_000, login: nil, password: "OLD1", totp: nil))
        XCTAssertEqual(s.history?[1].login, "o@example.invalid")
        XCTAssertEqual(s.deletedAt, 1_790_100_000)
    }

    func testSiteListDecodesHistoryCount() throws {
        let l = try CSNet.decode([["site": "Google", "login": true, "password": true, "totp": false, "history": 3]] as [[String: Any]],
                                 as: [SettingsVaultSite].self)
        XCTAssertEqual(l.first?.history, 3)
    }
}
