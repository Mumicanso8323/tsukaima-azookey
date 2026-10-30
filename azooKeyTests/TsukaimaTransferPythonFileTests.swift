import Foundation
import XCTest
@testable import azooKey

/// hub 側の変換道具(life/testflight-migration/tools/backup_to_transfer.py)が作ったファイルを、
/// Swift の読み込みが開けて、同じ規則で適用できること。ファイルは合成データ(反復 10 万回・テスト用の合言葉)。
final class TsukaimaTransferPythonFileTests: XCTestCase {
    private static let fixtureBase64 = "T0tUSwEAAYagytUhF7WISKegW8ZvhQIjWK55deU99DyOdV5WlPWm834hKRcwtUv6nENDjD5/0P3mCzYGSs38InDDK2n5/Kx7fhKilvaTcU/qORautokTm3xmi9lSSeq57aL/TlUj7iVsmkrPpuRYRHDy4OmilA3r1ml4FFxi7kZV3SEqZA762Fjw4gHPuF8eeukP4K7jWt81phYBpocMrFkpPz3AyTd9JxHhBzvxrwS4eZGaG/jr0f0Jq8UFcsIbKZENsaNBlzeoa8wEwJaHXf/NxsQxY7wg0FuZCLINjbOZ+EuDco+Eet18sL2wAgdb252k0PYdXd143v3pIpHarnpTOta4inSI4ycHkPxi/TzCoidzio1bxv4CEIv9FR1q4M5BIbGpwE6Pp440463uHGZg7qTcmf6EszsEDHO/AqO7CPJQ9HPbEpO5S03h9gqlm40V2ak+/c+yQH3kC7aj66cbOdRQkSLhszs+sIE3EAtO683Q93U/KYqDzws7ZmNXkZdg2EnEh0O7aocymKleoKMCZcVXG7R1UAP58ZmPdT1+5GDNHHRKqsO3y6So4AvP0TCDgVZrUM4+NYPoegnALR58rZK8o6DdYmIH+IwmRAtU7Fn8fZlZNdBZHgXQW01ncJH9wbkcCu7dTZgC6XvxhqUtN84ZckLp1t8FVbNeFxenMThB9j7il5tHhya7K8yaOXZgMRUyQvxLHoYX6CpASkoTiwV5aSX+vsPmm2T+Irw6LYl2nuSrwFxG3dGVm+vxlWvmttGuGA8yyu7IzZnBHrkSBI9EHwYvLj0bcu5LoXjCAZ6UmLsf8keo3ZEC20pqJNHp5xt9Udb42Vpew/paAikidMDGV1fWtUVyDnjTppAn1qRce+qnP7NNjT+WqYWOwglbAPmB+UHB0g=="
    private let pass = "synthetic-pass-0001"

    func testPythonMadeFileOpensAndAppliesLikeSwiftMadeOne() throws {
        let file = try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64))
        XCTAssertEqual(try TsukaimaTransferFile.Header.parse(file).iterations, 100_000)
        // 前後の空白は無視される(書き出し側と同じ)
        let payload = try TsukaimaTransfer.open(file, passphrase: "  " + pass + "\n")
        XCTAssertEqual(payload.files.count, 5)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("py-transfer-\(UUID().uuidString)")
        let docs = tmp.appendingPathComponent("Documents"), group = tmp.appendingPathComponent("Group")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let std = "py.transfer.std.\(UUID().uuidString)", grp = "py.transfer.grp.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: tmp)
            UserDefaults().removePersistentDomain(forName: std)
            UserDefaults().removePersistentDomain(forName: grp)
        }
        let env = TsukaimaTransfer.Environment(standard: UserDefaults(suiteName: std)!, standardDomain: std,
                                               group: UserDefaults(suiteName: grp)!, groupDomain: grp,
                                               documents: docs, groupContainer: group)
        XCTAssertEqual(TsukaimaTransfer.apply(payload, to: env), [])

        XCTAssertTrue(env.standard.bool(forKey: "naginata.enabled"))
        XCTAssertEqual(env.standard.double(forKey: "tsukaima.textSize"), 1.5)
        XCTAssertEqual(env.standard.string(forKey: "claude.draft"), "下書き")
        XCTAssertEqual(env.standard.stringArray(forKey: "photo.ids"), ["a", "b"])
        XCTAssertEqual(env.standard.integer(forKey: "count"), 7)
        XCTAssertEqual(env.standard.object(forKey: "photo.lastSyncAt") as? Date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(env.standard.data(forKey: "some.data"), Data([1, 2, 3]))
        XCTAssertEqual(env.group.string(forKey: "keyboard_type"), "flick")
        XCTAssertEqual(env.group.integer(forKey: "marked_text"), 42)
        func read(_ u: URL) -> String? { (try? Data(contentsOf: u)).flatMap { String(data: $0, encoding: .utf8) } }
        XCTAssertEqual(read(docs.appendingPathComponent("naginata-notes/note-1.txt")), "メモ一")
        XCTAssertEqual(read(docs.appendingPathComponent("naginata-practice-log.jsonl")), "log")
        XCTAssertEqual(read(group.appendingPathComponent("custard/a.json")), "custard-json")
        XCTAssertEqual(read(group.appendingPathComponent("user.louds")), "louds")
        // 運ばない物は入っていない
        XCTAssertNil(env.standard.object(forKey: "alarm.phase"))
        XCTAssertNil(env.standard.object(forKey: "my_device_token"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("Tsukaima/pairingFile.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: group.appendingPathComponent("clipboard_history.json").path))

        XCTAssertThrowsError(try TsukaimaTransfer.open(file, passphrase: "wrong-passphrase-x")) {
            XCTAssertEqual($0 as? TsukaimaTransferFile.Failure, .wrongPassphrase)
        }
    }
}
