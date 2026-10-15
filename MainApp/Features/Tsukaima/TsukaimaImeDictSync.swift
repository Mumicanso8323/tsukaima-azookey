import AzooKeyUtils
import Foundation

/// キーボードのユーザ辞書(hub 側 GET /api/ime/dict)を本体アプリ側で取得して App Group に書く。
/// キーボード拡張はネットワーク(Tailscale 含む)に一切出ない方針なので、取得はここ(TsukaimaAPI.shared
/// = api.yusukedoi.com + 端末の合鍵)だけが担う。起動・前面化のたびに呼ぶ(AppTabView の scenePhase)。
enum TsukaimaImeDictSync {
    private static let lastFetchKey = "imeDict.lastFetch"

    /// 前回の取得から TsukaimaImeDict.minFetchInterval 未満なら何もしない(force で無視できる)
    static func refreshIfNeeded(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        if !force {
            let last = UserDefaults.standard.double(forKey: lastFetchKey)
            guard now - last >= TsukaimaImeDict.minFetchInterval else { return }
        }
        UserDefaults.standard.set(now, forKey: lastFetchKey)
        Task {
            guard let payload: TsukaimaImeDict.Payload = try? await TsukaimaAPI.shared.get(TsukaimaImeDict.apiPath),
                  let data = try? JSONEncoder().encode(payload) else {
                return
            }
            TsukaimaImeDict.write(data, base: SharedStore.sharedContainerURL)
        }
    }
}
