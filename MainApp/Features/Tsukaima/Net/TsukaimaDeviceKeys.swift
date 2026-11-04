import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Secure Enclave の P-256 鍵 2 本(portal-bot docs/public-access-spec.md)。
/// - sign:   /api/main/* などの端末署名用。Face ID なし(.privateKeyUsage)。公開鍵は pair 時の sign_public_key。
/// - stepup: 危ない操作のステップアップ用。署名のたびに Face ID(.privateKeyUsage + .biometryAny)。
///           パスコードでは代われない(生体認証のみ)。公開鍵は /api/devices/native-key に預ける。
///           以前の版は .userPresence(パスコードでも通る)だったので、stepupVersion で作り直しを判定する。
/// 秘密鍵は Secure Enclave の外に出ない。Keychain には SE が暗号化した blob(dataRepresentation)だけを置く。
enum TsukaimaDeviceKeys {
    enum Kind: String { case sign, stepup }

    enum KeyError: LocalizedError {
        case unavailable, keychain, missing, accessControl, biometryUnavailable
        var errorDescription: String? {
            switch self {
            case .biometryUnavailable: "Face ID が使えません。iPhone の「設定」→「Face ID とパスコード」で Face ID をオンにしてから、もう一度お試しください"
            case .unavailable: "この端末では Secure Enclave が使えません"
            case .keychain: "鍵をキーチェーンに保存できませんでした"
            case .missing: "この端末の鍵が見つかりません。登録し直してください"
            case .accessControl: "鍵の設定を作れませんでした"
            }
        }
    }

    private static let service = "jp.yusukedoi.tsukaima.se-key"

    static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// Face ID(生体認証)が今この端末で使えるか
    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    // MARK: ステップアップ鍵の版(登録状態)

    /// 2 = 生体認証のみ(.biometryAny)でサーバ登録済み。0 = 作ったがサーバ登録に失敗。記録なし = 旧版(.userPresence)
    static let currentStepupVersion = 2
    private static let stepupVersionKey = "tsukaima.stepupKey.version"

    enum StepupState { case ok, unregistered, outdated }

    static var stepupState: StepupState {
        guard let v = UserDefaults.standard.object(forKey: stepupVersionKey) as? Int else { return .outdated }
        if v == currentStepupVersion && exists(.stepup) { return .ok }
        return v == 0 ? .unregistered : .outdated
    }

    static func setStepupVersion(_ v: Int?) {
        if let v { UserDefaults.standard.set(v, forKey: stepupVersionKey) } else { UserDefaults.standard.removeObject(forKey: stepupVersionKey) }
    }

    // MARK: 作成・保存

    /// Secure Enclave に鍵を作る(まだ Keychain には保存しない。サーバ登録が通ってから store する)
    static func make(_ kind: Kind) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard isAvailable else { throw KeyError.unavailable }
        if kind == .stepup && !biometryAvailable { throw KeyError.biometryUnavailable }
        let flags: SecAccessControlCreateFlags = kind == .sign ? [.privateKeyUsage] : [.privateKeyUsage, .biometryAny]
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else {
            throw KeyError.accessControl
        }
        do {
            return try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: ac)
        } catch {
            throw kind == .stepup ? KeyError.biometryUnavailable : error
        }
    }

    static func store(_ key: SecureEnclave.P256.Signing.PrivateKey, as kind: Kind) throws {
        guard TsukaimaKeychain.set(key.dataRepresentation, service: service, account: kind.rawValue) else {
            throw KeyError.keychain
        }
    }

    static func load(_ kind: Kind, context: LAContext? = nil) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let blob = TsukaimaKeychain.get(service: service, account: kind.rawValue) else { throw KeyError.missing }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    }

    static func exists(_ kind: Kind) -> Bool {
        TsukaimaKeychain.get(service: service, account: kind.rawValue) != nil
    }

    static func delete(_ kind: Kind) {
        TsukaimaKeychain.delete(service: service, account: kind.rawValue)
    }

    /// サーバの load_der_public_key が読む形(SPKI DER)を base64url で
    static func publicKeyB64(_ key: SecureEnclave.P256.Signing.PrivateKey) -> String {
        base64url(key.publicKey.derRepresentation)
    }

    /// ES256 で署名し、raw r‖s(64 バイト・low-S)を base64url で返す(deviceauth._raw_sig_to_der_low_s が受け付ける形)
    static func sign(_ key: SecureEnclave.P256.Signing.PrivateKey, _ message: Data) throws -> String {
        let sig = try key.signature(for: message)
        return base64url(lowS(sig.rawRepresentation))
    }

    // MARK: low-S 正規化

    // secp256r1 の位数 n と floor(n/2)(big-endian)
    private static let order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]
    private static let halfOrder: [UInt8] = [
        0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xDE, 0x73, 0x7D, 0x56, 0xD3, 0x8B, 0xCF, 0x42, 0x79, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8,
    ]

    /// s > n/2 なら s を n - s に置き換える(同じメッセージに対して等価な正当署名。サーバは low-S しか受理しない)
    static func lowS(_ raw: Data) -> Data {
        let bytes = [UInt8](raw)
        guard bytes.count == 64 else { return raw }
        let r = Array(bytes[0..<32])
        var s = Array(bytes[32..<64])
        if compare(s, halfOrder) > 0 { s = subtract(order, s) }
        return Data(r + s)
    }

    private static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for i in 0..<32 where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        return 0
    }

    /// a - b(a >= b、32 バイト big-endian)
    private static func subtract(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for i in stride(from: 31, through: 0, by: -1) {
            var d = Int(a[i]) - Int(b[i]) - borrow
            if d < 0 { d += 256; borrow = 1 } else { borrow = 0 }
            out[i] = UInt8(d)
        }
        return out
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
