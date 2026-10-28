import Foundation
import XCTest
@testable import azooKey

final class TsukaimaTransferTests: XCTestCase {
    private var tmp: URL!
    private var suites: [String] = []
    private let pass = "correct-horse-battery"
    private let iter = 100_000

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
    }

    private func makeEnv(_ name: String) throws -> TsukaimaTransfer.Environment {
        let std = "transfer.test.std.\(name).\(UUID().uuidString)"
        let grp = "transfer.test.grp.\(name).\(UUID().uuidString)"
        suites += [std, grp]
        let root = tmp.appendingPathComponent(name)
        let docs = root.appendingPathComponent("Documents"), group = root.appendingPathComponent("Group")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        return .init(standard: UserDefaults(suiteName: std)!, standardDomain: std,
                     group: UserDefaults(suiteName: grp)!, groupDomain: grp, documents: docs, groupContainer: group)
    }

    private func seed(_ env: TsukaimaTransfer.Environment) throws {
        env.standard.set(true, forKey: "naginata.enabled")
        env.standard.set(1.5, forKey: "tsukaima.textSize")
        env.standard.set("下書き", forKey: "claude.draft")
        env.standard.set(["a", "b"], forKey: "photo.ids")
        env.standard.set(Date(timeIntervalSince1970: 1_700_000_000), forKey: "photo.lastSyncAt")
        env.standard.set(Data([1, 2, 3]), forKey: "some.data")
        // 運ばない物
        env.standard.set("phase", forKey: "alarm.phase")
        env.standard.set("dev-id", forKey: "tsukaima.device.id")
        env.standard.set("x", forKey: "my_device_token")
        env.group.set("flick", forKey: "keyboard_type")
        env.group.set(42, forKey: "marked_text")
        let fm = FileManager.default
        try fm.createDirectory(at: env.documents.appendingPathComponent("naginata-notes"), withIntermediateDirectories: true)
        try Data("メモ一".utf8).write(to: env.documents.appendingPathComponent("naginata-notes/note-1.txt"))
        try Data("{\"ids\":[1]}".utf8).write(to: env.documents.appendingPathComponent("naginata-notes/index.json"))
        try Data("log".utf8).write(to: env.documents.appendingPathComponent("naginata-practice-log.jsonl"))
        try fm.createDirectory(at: env.documents.appendingPathComponent("Tsukaima"), withIntermediateDirectories: true)
        try Data("SECRET".utf8).write(to: env.documents.appendingPathComponent("Tsukaima/pairingFile.plist"))
        try fm.createDirectory(at: env.groupContainer.appendingPathComponent("custard"), withIntermediateDirectories: true)
        try Data("custard-json".utf8).write(to: env.groupContainer.appendingPathComponent("custard/a.json"))
        try Data("louds".utf8).write(to: env.groupContainer.appendingPathComponent("user.louds"))
        try Data("log".utf8).write(to: env.groupContainer.appendingPathComponent("kb-breadcrumb.log"))
        try fm.createDirectory(at: env.groupContainer.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: env.groupContainer.appendingPathComponent("Library/Preferences/x.plist"))
    }

    func testRoundTripRestoresEveryCarriedItem() throws {
        let src = try makeEnv("src"), dst = try makeEnv("dst")
        try seed(src)
        dst.standard.set(false, forKey: "naginata.enabled") // 上書きされる
        let (file, summary) = try TsukaimaTransfer.export(src, passphrase: pass, iterations: iter)
        XCTAssertEqual(summary.fileCount, 5)
        let payload = try TsukaimaTransfer.open(file, passphrase: pass)
        try TsukaimaTransfer.apply(payload, to: dst)

        XCTAssertTrue(dst.standard.bool(forKey: "naginata.enabled"))
        XCTAssertEqual(dst.standard.double(forKey: "tsukaima.textSize"), 1.5)
        XCTAssertEqual(dst.standard.string(forKey: "claude.draft"), "下書き")
        XCTAssertEqual(dst.standard.stringArray(forKey: "photo.ids"), ["a", "b"])
        XCTAssertEqual(dst.standard.object(forKey: "photo.lastSyncAt") as? Date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(dst.standard.data(forKey: "some.data"), Data([1, 2, 3]))
        XCTAssertEqual(dst.group.string(forKey: "keyboard_type"), "flick")
        XCTAssertEqual(dst.group.integer(forKey: "marked_text"), 42)
        func read(_ u: URL) -> String? { (try? Data(contentsOf: u)).flatMap { String(data: $0, encoding: .utf8) } }
        XCTAssertEqual(read(dst.documents.appendingPathComponent("naginata-notes/note-1.txt")), "メモ一")
        XCTAssertEqual(read(dst.documents.appendingPathComponent("naginata-notes/index.json")), "{\"ids\":[1]}")
        XCTAssertEqual(read(dst.documents.appendingPathComponent("naginata-practice-log.jsonl")), "log")
        XCTAssertEqual(read(dst.groupContainer.appendingPathComponent("custard/a.json")), "custard-json")
        XCTAssertEqual(read(dst.groupContainer.appendingPathComponent("user.louds")), "louds")
    }

    func testSecretsAndDeviceStateAreNotCarried() throws {
        let src = try makeEnv("src"), dst = try makeEnv("dst")
        try seed(src)
        let (file, _) = try TsukaimaTransfer.export(src, passphrase: pass, iterations: iter)
        try TsukaimaTransfer.apply(try TsukaimaTransfer.open(file, passphrase: pass), to: dst)
        XCTAssertNil(dst.standard.object(forKey: "alarm.phase"))
        XCTAssertNil(dst.standard.object(forKey: "tsukaima.device.id"))
        XCTAssertNil(dst.standard.object(forKey: "my_device_token"))
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dst.documents.appendingPathComponent("Tsukaima/pairingFile.plist").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.groupContainer.appendingPathComponent("kb-breadcrumb.log").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.groupContainer.appendingPathComponent("Library").path))
        // 暗号文に平文の秘密が見えない
        XCTAssertNil(file.range(of: Data("SECRET".utf8)))
    }

    func testWrongPassphraseFails() throws {
        let src = try makeEnv("src")
        try seed(src)
        let (file, _) = try TsukaimaTransfer.export(src, passphrase: pass, iterations: iter)
        XCTAssertThrowsError(try TsukaimaTransfer.open(file, passphrase: "wrong-passphrase")) {
            XCTAssertEqual($0 as? TsukaimaTransferFile.Failure, .wrongPassphrase)
        }
    }

    func testCorruptFilesFail() throws {
        let src = try makeEnv("src")
        try seed(src)
        let (file, _) = try TsukaimaTransfer.export(src, passphrase: pass, iterations: iter)
        // 途中を1バイト壊す → 認証タグで落ちる
        var bad = file
        bad[bad.count / 2] ^= 0xFF
        XCTAssertThrowsError(try TsukaimaTransfer.open(bad, passphrase: pass))
        // 見出しを壊す
        var badHeader = file
        badHeader[0] = 0x00
        XCTAssertThrowsError(try TsukaimaTransfer.open(badHeader, passphrase: pass)) {
            XCTAssertEqual($0 as? TsukaimaTransferFile.Failure, .notTransferFile)
        }
        // 途切れたファイル・空・別物
        XCTAssertThrowsError(try TsukaimaTransfer.open(file.prefix(30), passphrase: pass))
        XCTAssertThrowsError(try TsukaimaTransfer.open(Data(), passphrase: pass))
        XCTAssertThrowsError(try TsukaimaTransfer.open(Data("hello world".utf8), passphrase: pass))
    }

    func testShortPassphraseRejected() throws {
        let src = try makeEnv("src")
        XCTAssertThrowsError(try TsukaimaTransfer.export(src, passphrase: "short", iterations: iter)) {
            XCTAssertEqual($0 as? TsukaimaTransferFile.Failure, .shortPassphrase)
        }
    }

    func testUnsafePathsAreRejected() {
        XCTAssertFalse(TsukaimaTransfer.isSafe(root: .group, path: "../x"))
        XCTAssertFalse(TsukaimaTransfer.isSafe(root: .group, path: "/etc/passwd"))
        XCTAssertFalse(TsukaimaTransfer.isSafe(root: .group, path: "Library/Preferences/x.plist"))
        XCTAssertFalse(TsukaimaTransfer.isSafe(root: .documents, path: "Tsukaima/pairingFile.plist"))
        XCTAssertFalse(TsukaimaTransfer.isSafe(root: .documents, path: "naginata-notes/../Tsukaima/x"))
        XCTAssertTrue(TsukaimaTransfer.isSafe(root: .documents, path: "naginata-notes/note-1.txt"))
        XCTAssertTrue(TsukaimaTransfer.isSafe(root: .group, path: "custard/a.json"))
    }
}
