//
//  VaultRevealTests.swift
//  保管庫の「Face ID で値を表示」まわりの純粋な部分(応答の解析・クリップボードの設定・伏せ字)。値はすべて偽物。
//

import Foundation
import SwiftUI
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

    // MARK: 取得の重複(Face ID ループの再現)

    private func fake(_ site: String) -> SettingsVaultSecret { SettingsVaultSecret(site: site, login: "u@example.invalid", password: "FAKE") }

    /// 同じ項目の取得が並行で何本来ても、実際の取得(= Face ID)は 1 回だけ
    func testConcurrentRevealOfSameSiteRunsOnce() async throws {
        let c = VaultRevealCoalescer()
        var calls = 0
        let op: @MainActor () async throws -> SettingsVaultSecret = {
            calls += 1
            try await Task.sleep(nanoseconds: 200_000_000)
            return self.fake("a")
        }
        async let r1 = c.run("a", op: op)
        async let r2 = c.run("a", op: op)
        async let r3 = c.run("a", op: op)
        let all = try await [r1, r2, r3]
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(all.allSatisfy { $0 == fake("a") })
    }

    /// 待っている側(画面の .task)が取り消されても取得は続き、作り直された画面が同じ取得に相乗りする
    func testCancelledWaiterDoesNotStartSecondFetch() async throws {
        let c = VaultRevealCoalescer()
        var calls = 0
        let op: @MainActor () async throws -> SettingsVaultSecret = {
            calls += 1
            try await Task.sleep(nanoseconds: 300_000_000)
            return self.fake("a")
        }
        let first = Task { @MainActor in try await c.run("a", op: op) }
        try await Task.sleep(nanoseconds: 50_000_000)
        first.cancel()
        let second = try await c.run("a", op: op)  // 画面の作り直し
        XCTAssertEqual(second, fake("a"))
        XCTAssertEqual(calls, 1)
    }

    /// 終わったあとの押し直しは新しく取りに行く(毎回 Face ID)。別の項目は別々
    func testSequentialAndDifferentSites() async throws {
        let c = VaultRevealCoalescer()
        var calls: [String] = []
        func op(_ s: String) -> @MainActor () async throws -> SettingsVaultSecret {
            { calls.append(s); return self.fake(s) }
        }
        _ = try await c.run("a", op: op("a"))
        _ = try await c.run("a", op: op("a"))
        async let x = c.run("b", op: op("b"))
        async let y = c.run("c", op: op("c"))
        _ = try await (x, y)
        XCTAssertEqual(calls.sorted(), ["a", "a", "b", "c"])
        XCTAssertFalse(c.isRunning("a"))
    }

    /// 失敗(Face ID の取り消し)しても自動では再試行しない。次の押し直しだけが新しい取得になる
    func testFailureIsNotRetriedAutomatically() async {
        let c = VaultRevealCoalescer()
        var calls = 0
        let op: @MainActor () async throws -> SettingsVaultSecret = { calls += 1; throw TsukaimaAPIError.stepupCancelled }
        do { _ = try await c.run("a", op: op); XCTFail("投げるはず") } catch {}
        XCTAssertEqual(calls, 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(c.isRunning("a"))
    }

    /// Face ID の間は .inactive になる。そこでは何もしない。背面に回ったときだけ伏せて閉じる
    func testInactiveDoesNothingBackgroundCloses() {
        XCTAssertFalse(VaultScenePolicy.shouldHideValues(.inactive))
        XCTAssertFalse(VaultScenePolicy.shouldClose(.inactive))
        XCTAssertFalse(VaultScenePolicy.shouldHideValues(.active))
        XCTAssertTrue(VaultScenePolicy.shouldHideValues(.background))
        XCTAssertTrue(VaultScenePolicy.shouldClose(.background))
    }
}
