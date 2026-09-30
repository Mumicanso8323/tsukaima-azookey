import Darwin
import Foundation
import IDevice  // fork(Mumicanso8323/idevice)の C FFI 一式 + 同梱の libplist。
                // IDevice.xcframework の各スライスに module.modulemap が同梱されているので
                // (docs/tsukaima-springboard-icon-integration.md §2)、bridging header は不要。

/// idevice fork の SpringBoardServices FFI の薄いラッパー。LocalDevVPN(SideStore 用に既に導入・
/// 使用中の NetworkExtension)経由で自分の端末の lockdownd に TCP で繋ぎ、ホーム画面のアイコン配置
/// (icon state)を読み取るだけの読み取り専用デモ
/// (docs/tsukaima-springboard-icon-integration.md §3 ステップ4に対応。set_icon_state はまだ呼ばない)。
///
/// すべて同期・ブロッキング呼び出し(Rust 側が内部でブロックする)。呼び出し側は必ずバックグラウンドの
/// Task から呼ぶこと(SettingsSpringboardSection 参照)。ペアリング記録・トークンの中身は絶対に
/// ログ・画面に出さない — エラーは定型文に丸め、plist の生データも UI には要約(ページ数・Dock数)しか出さない。
enum TsukaimaIdeviceError: LocalizedError {
    case pairingFileInvalid
    case connectionFailed
    case plistDecodeFailed

    var errorDescription: String? {
        switch self {
        case .pairingFileInvalid: "ペアリングファイルを読み取れませんでした"
        case .connectionFailed: "端末に接続できませんでした(LocalDevVPN が接続中か確認してください)"
        case .plistDecodeFailed: "応答を読み取れませんでした"
        }
    }
}

struct TsukaimaIconStateSummary {
    /// SpringBoard の IconState.plist で広く知られたキー名から集計(iconLists = ページごとの配列、
    /// buttonBar = Dock)。実機でこのフォークの `get_icon_state` が返す形を確認できていないため、
    /// キーが見つからなければ nil のまま返す(壊れた集計を出すより「わからない」を出す)。
    var pageCount: Int?
    var dockAppCount: Int?
    var topLevelKeys: [String]
}

enum TsukaimaIdeviceBridge {
    /// 「要確認」だったポート番号は、fork の xcframework ヘッダ自身が
    /// `#define LOCKDOWN_PORT 62078` を公開している事実(idevice.h 28行目、examples/heartbeat.c も
    /// 同じ値を使う)をもって解消し、第一候補にした。StikJIT の統合ガイドが挙げる 49152 は
    /// 用途が別(RSD 系トンネルのエンドポイントである可能性が高い)と見ているが実機でしか確定できない
    /// ため、フォールバックとしてだけ残す。
    static let candidatePorts: [UInt16] = [62078, 49152]
    static let vpnHost = "10.7.0.1"

    /// 読み取り専用デモ本体。呼び出し側(バックグラウンド)で同期的に完了する。
    static func readIconStateSummary(pairingFileData: Data) throws -> TsukaimaIconStateSummary {
        var lastError: Error = TsukaimaIdeviceError.connectionFailed
        for port in candidatePorts {
            do {
                return try attempt(pairingFileData: pairingFileData, port: port)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func attempt(pairingFileData: Data, port: UInt16) throws -> TsukaimaIconStateSummary {
        // 1) ペアリングファイルをバイト列から読む(取り込み時に読み込んだ Data をそのまま渡す。
        //    ディスクパスをここに持ち込まない = 呼び出し側の責務にしない)
        var pairingFile: OpaquePointer?
        let pairingRC = pairingFileData.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
            idevice_pairing_file_from_bytes(raw.bindMemory(to: UInt8.self).baseAddress, UInt(raw.count), &pairingFile)
        }
        try throwIfError(pairingRC)
        guard let pairingFile else { throw TsukaimaIdeviceError.pairingFileInvalid }

        // 2) sockaddr_in を組み立てて TCP provider を作る。
        //    「pairing_file is consumed」(idevice.h の Safety 注記)なので、成功・失敗を問わず
        //    ここで pairingFile を自分で free してはいけない(呼び先が引き取る契約)。
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(vpnHost)

        var provider: OpaquePointer?
        let providerRC = withUnsafePointer(to: &addr) { addrPtr -> UnsafeMutablePointer<IdeviceFfiError>? in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                "tsukaima".withCString { label in
                    idevice_tcp_provider_new(sa, pairingFile, label, &provider)
                }
            }
        }
        try throwIfError(providerRC)
        guard let provider else { throw TsukaimaIdeviceError.connectionFailed }
        defer { idevice_provider_free(provider) }  // provider は borrow only。呼び手が最後に解放する

        // 3) springboardservices に繋ぐ(classic lockdown 経由。RSD フォールバックは §5 の宿題のまま、
        //    呼び出し口 [springboard_services_connect_rsd] だけ fork 側に残っている)
        var client: OpaquePointer?
        let connectRC = springboard_services_connect(provider, &client)
        try throwIfError(connectRC)
        guard let client else { throw TsukaimaIdeviceError.connectionFailed }
        defer { springboard_services_free(client) }

        // 4) get_icon_state → plist_t
        var result: UnsafeMutableRawPointer?
        let getRC = springboard_services_get_icon_state(client, nil, &result)
        try throwIfError(getRC)
        guard let result else { throw TsukaimaIdeviceError.plistDecodeFailed }
        defer { plist_free(result) }

        // 5) C の木を自前で辿らず、plist_to_xml → PropertyListSerialization に任せる
        //    (docs …integration.md §3-5 で「実装コストが低い」として挙げていた方式。
        //    plist_dict_get_item 等の getter 群は同梱の libplist に確かに存在するが、ここでは使わない)
        var xmlPtr: UnsafeMutablePointer<CChar>?
        var xmlLen: UInt32 = 0
        let xmlRC = plist_to_xml(result, &xmlPtr, &xmlLen)
        guard xmlRC == PLIST_ERR_SUCCESS, let xmlPtr else { throw TsukaimaIdeviceError.plistDecodeFailed }
        defer { free(xmlPtr) }  // libplist 側は malloc で確保する(plist_free とは別物。混同しない)

        let xmlData = Data(bytes: xmlPtr, count: Int(xmlLen))
        guard let obj = try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil),
              let dict = obj as? [String: Any] else {
            throw TsukaimaIdeviceError.plistDecodeFailed
        }
        let pageCount = (dict["iconLists"] as? [Any])?.count
        let dockCount = (dict["buttonBar"] as? [Any])?.count
        return TsukaimaIconStateSummary(pageCount: pageCount, dockAppCount: dockCount, topLevelKeys: Array(dict.keys))
    }

    /// IdeviceFfiError の中身(code/sub_code はともかく message)はペアリング関連の生情報を含み得る
    /// 設計ではない([要確認]なし、fork のコメントに機微情報が乗る想定は無いが)、念のため画面には
    /// 一切出さず定型文に丸める。ログにも出さない。
    private static func throwIfError(_ err: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let err else { return }
        idevice_error_free(err)
        throw TsukaimaIdeviceError.connectionFailed
    }
}
