import Photos
import SwiftUI
import UIKit

/// 「写真の自動バックアップ」設定。オン/オフ・許可の状態・最後に送った時刻を出す
/// (SettingsLocationSection と同じ流儀)。オンにした瞬間だけ、その時点より後の新しい写真・
/// スクリーンショットが対象になる(既存の写真は遡らない)。
struct SettingsPhotoBackupSection: View {
    @ObservedObject private var backup = TsukaimaPhotoBackup.shared

    var body: some View {
        Section {
            Toggle("写真を自動で hub に送る", isOn: $backup.enabled)
            HStack {
                Text("許可の状態")
                Spacer()
                Text(Self.statusLabel(backup.authorizationStatus))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("最後に送った時刻")
                Spacer()
                if backup.isSyncing {
                    ProgressView()
                } else {
                    Text(Self.lastSyncLabel(backup.lastSyncAt))
                        .foregroundStyle(.secondary)
                }
            }
            if backup.needsSettingsAppUpgrade {
                Button("設定アプリで写真へのアクセスを許可") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            if let err = backup.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("写真の自動バックアップ")
        } footer: {
            Text("オンにした時点より後に撮った写真・スクリーンショットだけを、アプリを開くたびに hub へ送ります(既存の写真は遡りません)。同じ写真を二重に送ることはありません。")
        }
    }

    private static func statusLabel(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: "未確認"
        case .restricted: "制限あり"
        case .denied: "許可されていません"
        case .limited: "一部の写真のみ"
        case .authorized: "すべての写真"
        @unknown default: "不明"
        }
    }

    private static func lastSyncLabel(_ d: Date?) -> String {
        guard let d else { return "まだ送っていません" }
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: d)
    }
}
