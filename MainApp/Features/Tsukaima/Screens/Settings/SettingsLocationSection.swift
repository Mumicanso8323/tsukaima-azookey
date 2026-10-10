import CoreLocation
import SwiftUI
import UIKit

/// 「位置情報」設定。オン/オフ・最後に送った時刻・許可の状態を出す。
/// オンにすると TsukaimaLocationService が使用中→常に、の順で許可を求める(本人指定の順番)。
/// 予定の出発・準備・開始5分前の通知は hub 側(portal-bot bot/icloud.py)が現在地から計算する。
struct SettingsLocationSection: View {
    @ObservedObject private var service = TsukaimaLocationService.shared

    var body: some View {
        Section {
            Toggle("位置情報を送る", isOn: $service.enabled)
            HStack {
                Text("許可の状態")
                Spacer()
                Text(Self.statusLabel(service.authorizationStatus))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("最後に送った時刻")
                Spacer()
                Text(Self.lastSentLabel(service.lastSentAt))
                    .foregroundStyle(.secondary)
            }
            if service.needsAlwaysUpgrade {
                Button("設定アプリで「常に」に変更") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            if let err = service.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("位置情報")
        } footer: {
            Text("今いる場所から予定への移動時間を見積もり、原付での「出発」「準備(10分前)」「開始5分前」の通知を自動で付けます。電池を使う常時追跡はせず、大きな移動・到着/出発の検知と、アプリを開いている間だけ約10分おきの1回で済ませます。常時許可(常に)が無いと、アプリを閉じている間は更新されません。")
        }
    }

    private static func statusLabel(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: "未確認"
        case .restricted: "制限あり"
        case .denied: "許可されていません"
        case .authorizedWhenInUse: "使用中のみ"
        case .authorizedAlways: "常に"
        @unknown default: "不明"
        }
    }

    private static func lastSentLabel(_ d: Date?) -> String {
        guard let d else { return "まだ送っていません" }
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: d)
    }
}
