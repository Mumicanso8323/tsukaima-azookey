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
    enum Tab: Hashable {
        case tips
        case theme
        case customization
        case tsukaima
        case settings
    }

    @Published var selectedTab: Tab = .tips
    @Published var settingsPath: [SettingsRoute] = []
    @Published var importedFileURL: URL?
    @Published var tsukaimaRecordRequest: TsukaimaRecordRequest?

    func open(_ url: URL) {
        if ["azookey", "tsukaima-azookey"].contains(url.scheme?.lowercased() ?? "") {
            let host = url.host?.lowercased()
            let lastPathComponent = url.lastPathComponent.lowercased()
            if host == "settings", lastPathComponent == "zenzai" {
                selectedTab = .settings
                settingsPath.append(.zenzai)
            }
            return
        }

        if url.scheme?.lowercased() == "tsukaima-rec" {
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
}
