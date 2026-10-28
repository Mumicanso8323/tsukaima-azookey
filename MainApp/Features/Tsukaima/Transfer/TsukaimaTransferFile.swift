import Foundation
import CryptoKit
import CommonCrypto

/// 引き継ぎファイルの入れ物(ccf v2.1 の引き継ぎと同じ形式: docs/v2.1-gm.md 付録 A)。
/// バイト列(数はビッグエンディアン):
/// `OKTK`(4) | 版 01(1) | PBKDF2 の反復回数 uint32(4) | 塩(16) | nonce(12) | AES-256-GCM の暗号文 + タグ(16)
/// 鍵 = PBKDF2-HMAC-SHA256(合言葉を NFC に揃えた UTF-8, 塩, 反復回数, 32 バイト)。AAD は先頭 37 バイト。
/// 平文は使い魔の引き継ぎ内容(TsukaimaTransfer.Payload の plist)。合言葉・平文はログに出さない。
enum TsukaimaTransferFile {
    static let magic = Data("OKTK".utf8)
    static let version: UInt8 = 1
    static let headerLength = 37
    static let tagLength = 16
    static let defaultIterations = 600_000
    /// 読み込みで受け付ける反復回数(弱いファイル・重すぎるファイルを開かない)
    static let iterationRange = 100_000...10_000_000
    /// 学習データ・テーマ画像を含むため ccf より大きく取る
    static let maxFileSize = 96 * 1024 * 1024
    static let fileExtension = "tsukaima-transfer"
    static let minPassphrase = 12

    enum Failure: LocalizedError, Equatable {
        case notTransferFile
        case newerVersion
        case wrongPassphrase
        case unsupported
        case shortPassphrase
        case tooLarge
        case nothingToCarry

        var errorDescription: String? {
            switch self {
            case .notTransferFile: return "引き継ぎファイルではないか、壊れています。"
            case .newerVersion: return "新しい形式の引き継ぎファイルです。アプリを新しくしてから読み込んでください。"
            case .wrongPassphrase: return "合言葉が違うか、ファイルが壊れています。"
            case .unsupported: return "この端末では引き継ぎファイルを扱えません。"
            case .tooLarge: return "ファイルの中身が大きすぎるため読み込めません。"
            case .nothingToCarry: return "運ぶ設定・ファイルが見つかりませんでした(App Group を読めていない可能性があります)。書き出しを中止しました。"
            case .shortPassphrase: return "合言葉は\(TsukaimaTransferFile.minPassphrase)文字以上にしてください。"
            }
        }
    }

    struct Header: Equatable {
        var iterations: UInt32
        var salt: Data
        var nonce: Data

        var bytes: Data {
            var d = TsukaimaTransferFile.magic
            d.append(TsukaimaTransferFile.version)
            withUnsafeBytes(of: iterations.bigEndian) { d.append(contentsOf: $0) }
            d.append(salt)
            d.append(nonce)
            return d
        }

        /// 合言葉を聞く前に断るもの
        static func parse(_ file: Data) throws -> Header {
            let f = Data(file)
            guard f.count <= TsukaimaTransferFile.maxFileSize,
                  f.count >= TsukaimaTransferFile.headerLength + TsukaimaTransferFile.tagLength,
                  f.prefix(4) == TsukaimaTransferFile.magic else { throw Failure.notTransferFile }
            guard f[4] == TsukaimaTransferFile.version else { throw Failure.newerVersion }
            let iterations = f[5..<9].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard TsukaimaTransferFile.iterationRange.contains(Int(iterations)) else { throw Failure.notTransferFile }
            return Header(iterations: iterations, salt: Data(f[9..<25]), nonce: Data(f[25..<37]))
        }
    }

    static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    /// 前後の空白・改行は書き出し側も読み込み側も無視する
    static func trimmed(_ passphrase: String) -> String {
        passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalized(_ passphrase: String) -> Data {
        Data(trimmed(passphrase).precomposedStringWithCanonicalMapping.utf8)
    }

    /// 書き出し。塩と nonce はテストのときだけ渡す(普段は毎回乱数)
    static func seal(plaintext: Data, passphrase: String, iterations: Int = defaultIterations,
                     salt: Data? = nil, nonce: Data? = nil) throws -> Data {
        guard trimmed(passphrase).count >= minPassphrase else { throw Failure.shortPassphrase }
        guard iterationRange.contains(iterations) else { throw Failure.unsupported }
        let header = Header(iterations: UInt32(iterations), salt: salt ?? randomBytes(16), nonce: nonce ?? randomBytes(12))
        let key = try deriveKey(passphrase, salt: header.salt, iterations: iterations)
        let aad = header.bytes
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                   nonce: AES.GCM.Nonce(data: header.nonce), authenticating: aad)
        return aad + box.ciphertext + box.tag
    }

    /// 読み込み。合言葉で開いて平文を返す
    static func openPlaintext(_ file: Data, passphrase: String) throws -> Data {
        let f = Data(file)
        let header = try Header.parse(f)
        let key = try deriveKey(passphrase, salt: header.salt, iterations: Int(header.iterations))
        let body = Data(f.dropFirst(headerLength))
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: header.nonce),
                                            ciphertext: body.dropLast(tagLength), tag: body.suffix(tagLength))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(f.prefix(headerLength)))
        } catch {
            throw Failure.wrongPassphrase
        }
    }

    static func deriveKey(_ passphrase: String, salt: Data, iterations: Int) throws -> Data {
        let pass = normalized(passphrase)
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { k in
            salt.withUnsafeBytes { s in
                pass.withUnsafeBytes { p in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         p.baseAddress?.assumingMemoryBound(to: Int8.self), pass.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         k.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.unsupported }
        return key
    }
}
