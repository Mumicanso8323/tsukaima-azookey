import Foundation
import SwiftUI

/// tsukaima-rec://record?course=... で「使い魔」タブを開いて即録音を始める。
/// tsukaima-rec:// (host無し)はタブを開くだけ。id を持たせて同じ course でも onChange が確実に発火するようにする。
struct TsukaimaRecordRequest: Equatable {
    let id = UUID()
    let course: String?
}

@MainActor
final class AppRouter: ObservableObject {
    /// 下のタブバー: ホーム(今日/勉強/生活) / 使い魔 / 設定。
    /// 今日・勉強・生活は独立タブではなく、HomeTabView の中の上部セグメント(使い魔タブと同じパターン)。
    /// azooKey 由来の tips・theme・customization・settings(キーボードの設定)は「設定」タブの中の
    /// 「キーボード」側で keyboardTab として使う(.settings は外側の「設定」タブのタグも兼ねる)。
    enum Tab: Hashable {
        case home
        case tips
        case theme
        case customization
        case tsukaima
        case claude
        case settings
    }

    /// 「設定」タブの中の切り替え(使い魔の設定 / キーボード(azooKey)の設定)
    enum SettingsSection: Hashable {
        case tsukaima
        case keyboard
    }

    @Published var selectedTab: Tab = AppRouter.initialTab()
    @Published var settingsSection: SettingsSection = .tsukaima
    @Published var keyboardTab: Tab = .settings
    @Published var settingsPath: [SettingsRoute] = []
    @Published var importedFileURL: URL?
    @Published var tsukaimaRecordRequest: TsukaimaRecordRequest?
    /// SideStore からのペアリングファイル取り込みの直近の結果(nil = まだ無い)。設定画面が案内に使う
    @Published var pairingFileImportSucceeded: Bool?

    func open(_ url: URL) {
        if ["azookey", "tsukaima-azookey"].contains(url.scheme?.lowercased() ?? "") {
            let host = url.host?.lowercased()
            let lastPathComponent = url.lastPathComponent.lowercased()
            if host == "settings", lastPathComponent == "zenzai" {
                selectedTab = .settings
                settingsSection = .keyboard
                keyboardTab = .settings
                settingsPath.append(.zenzai)
            }
            return
        }

        if url.scheme?.lowercased() == "tsukaima-rec" {
            // SideStore からのペアリングファイル書き出し(tsukaima-rec://pairingFile?data=<base64>)。
            // 中身は保存するだけで、ログにも画面にも出さない。設定タブに戻して結果を見せる。
            if url.host?.lowercased() == "pairingfile" {
                pairingFileImportSucceeded = TsukaimaPairingFileStore.importIfPairingCallback(url)
                selectedTab = .settings
                settingsSection = .tsukaima
                return
            }
            selectedTab = .tsukaima
            if url.host?.lowercased() == "record" {
                let course = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "course" }?.value
                tsukaimaRecordRequest = TsukaimaRecordRequest(course: course?.isEmpty == false ? course : nil)
            }
            return
        }

        importedFileURL = url
    }

    /// 目覚ましが鳴っている・二度寝チェック中・セット中なら最初から「使い魔」タブ(問題画面を一瞬でも隠さない)。
    /// それ以外は「ホーム」(今日セグメント)。キーは TsukaimaAlarm.phaseKey と同じ。
    nonisolated static func initialTab() -> Tab {
        let phase = UserDefaults.standard.string(forKey: "alarm.phase") ?? "off"
        return phase == "off" ? .home : .tsukaima
    }
}
