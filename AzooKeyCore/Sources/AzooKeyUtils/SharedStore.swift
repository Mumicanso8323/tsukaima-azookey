//
//  SharedStore.swift
//  azooKey
//
//  Created by ensan on 2020/11/20.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation
import KeyboardViews
import SwiftUtils

public enum SharedStore {
    @MainActor public static let userDefaults = UserDefaults(suiteName: Self.appGroupKey) ?? .standard
    /// 使い魔azooKey: App Store 版 azooKey と衝突しないよう bundle ID / App Group を独自のものにする。
    /// SideStore は bundle ID の末尾にチーム ID を足すことがあるので、判定は前方一致で行う(呼び出し側は hasPrefix)。
    public static let bundleName = "jp.yusukedoi.tsukaima.azookey.keyboard"
    public static let defaultAppGroupKey = "group.jp.yusukedoi.tsukaima.azookey"
    /// SideStore / AltStore は再署名時に App Group ID を書き換え(チーム ID 付き)、実際の ID を Info.plist の `ALTAppGroups` に入れる。
    /// それがあればそちらを使い、無ければ既定値。
    public static let appGroupKey: String = resolveAppGroupKey(
        altAppGroups: Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
    )

    public static func resolveAppGroupKey(altAppGroups: [String]?) -> String {
        guard let groups = altAppGroups?.filter({ !$0.isEmpty }), !groups.isEmpty else {
            return defaultAppGroupKey
        }
        return groups.first(where: { $0.hasPrefix(defaultAppGroupKey) }) ?? groups[0]
    }

    /// App Group のコンテナ。App Group が使えない署名(プロビジョニング不備)でも落ちないよう、
    /// その場合は自分の Application Support 以下を使う(本体とキーボードで設定が共有されなくなるだけ)。
    public static let sharedContainerURL: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupKey) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SharedFallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()

    private static var appVersionString: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
    private static let initialAppVersionKey = "InitialAppVersion"
    private static let lastAppVersionKey = "LastAppVersion"
    private static let resolvedKeyboardSizeVerticalKey = "ResolvedKeyboardSizeVertical"
    private static let resolvedKeyboardSizeHorizontalKey = "ResolvedKeyboardSizeHorizontal"

    private static func resolvedKeyboardSizeKey(
        orientation: KeyboardOrientation
    ) -> String {
        switch orientation {
        case .vertical:
            resolvedKeyboardSizeVerticalKey
        case .horizontal:
            resolvedKeyboardSizeHorizontalKey
        }
    }

    @MainActor
    public static func resolvedKeyboardSize(
        orientation: KeyboardOrientation
    ) -> CGSize? {
        guard let value = userDefaults.dictionary(
            forKey: resolvedKeyboardSizeKey(orientation: orientation)
        ),
        let width = value["width"] as? NSNumber,
        let height = value["height"] as? NSNumber,
        width.doubleValue > 0,
        height.doubleValue > 0 else {
            return nil
        }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    @MainActor
    public static func setResolvedKeyboardSize(
        _ size: CGSize,
        orientation: KeyboardOrientation
    ) {
        guard size.width > 0, size.height > 0 else {
            return
        }
        userDefaults.set(
            [
                "width": size.width,
                "height": size.height,
            ],
            forKey: resolvedKeyboardSizeKey(orientation: orientation)
        )
    }

    public static var currentAppVersion: AppVersion? {
        if let appVersionString = appVersionString {
            return AppVersion(appVersionString)
        }
        return nil
    }
    // this value will be 1.7.1 at minimum
    @MainActor public static var initialAppVersion: AppVersion? {
        if let appVersionString = userDefaults.string(forKey: initialAppVersionKey) {
            return AppVersion(appVersionString)
        }
        return nil
    }

    // this value will be 2.0.0 at minimum
    @MainActor public static var lastAppVersion: AppVersion? {
        if let appVersionString = userDefaults.string(forKey: lastAppVersionKey) {
            return AppVersion(appVersionString)
        }
        return nil
    }

    @MainActor public static func setInitialAppVersion() {
        if initialAppVersion == nil, let appVersionString = appVersionString {
            SharedStore.userDefaults.set(appVersionString, forKey: initialAppVersionKey)
        }
    }

    @MainActor public static func setLastAppVersion() {
        if let appVersionString = appVersionString {
            SharedStore.userDefaults.set(appVersionString, forKey: lastAppVersionKey)
        }
    }

    public enum ShareThisWordOptions: String, Sendable {
        case 人・動物・会社などの名前
        case 場所・建物などの名前
        case 五段活用
    }

    public static func sendSharedWord(word: String, ruby: String, note: String? = nil, options: [ShareThisWordOptions]) async -> Bool {
        let url = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSceGtIHH8P-KbrB2ownprap3cUVVJegbhGekfz1xCiwPxBNfg/formResponse")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("no-cors", forHTTPHeaderField: "mode")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let importanceKey = 1129894332 // 重要度、1~5
        let wordKey = 813756984  // 単語、文字列
        let rubyKey = 688013311  // ルビ、文字列
        let categoryKey = 2110887544 // 品詞
        let noteKey = 1136445695  // 備考

        var parameters = "entry.\(importanceKey)=3&entry.\(wordKey)=\(word)&entry.\(rubyKey)=\(ruby.isEmpty ? "読み記入なし" : ruby)"

        let note = (note ?? "備考記入なし") + "\n" + "アプリ内フォームから送信" + "\n" + "azooKeyのバージョン: \(SharedStore.appVersionString ?? "不明")"
        parameters += "&entry.\(noteKey)=\(note)"

        parameters += "&entry.\(categoryKey)=__other_option__"
        let categoryInfo = options.map {$0.rawValue}.joined(separator: "、")
        parameters += "&entry.\(categoryKey).other_option_response=\(categoryInfo.isEmpty ? "品詞記入無し" : categoryInfo)"
        request.httpBody = parameters
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .data(using: .utf8) ?? Data()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            debug("sendSharedWord response", parameters, response)
            return true
        } catch {
            debug("sendSharedWord error", error)
            return false
        }
    }
}
