//
//  TipsNewsSection.swift
//  azooKey
//
//  Created by miwa on 2023/11/11.
//  Copyright © 2023 DevEn3. All rights reserved.
//

import SwiftUI

struct TipsNewsSection: View {
    @AppStorage("read_article_iOS15_service_termination") private var readArticle_iOS15_service_termination = false
    @EnvironmentObject private var appStates: MainAppStates

    @MainActor
    private var needUseShiftKeySettingNews: Bool {
        appStates.englishLayout == .qwerty
    }

    @MainActor
    private var needUseFlickCustomSettingNews: Bool {
        appStates.japaneseLayout != .qwerty || appStates.englishLayout != .qwerty
    }

    @MainActor
    private var needFlickDakutenKeyNews: Bool {
        appStates.japaneseLayout != .qwerty
    }

    var iOS16TerminationNewsViewLabel: some View {
        Label(
            title: {
                Text("iOS 16のサポートを終了します")
            },
            icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        )
    }
    var body: some View {
        if #unavailable(iOS 17) {
            Section("お知らせ") {
                NavigationLink(destination: iOS15TerminationNewsView($readArticle_iOS15_service_termination)) {
                    if !readArticle_iOS15_service_termination {
                        iOS16TerminationNewsViewLabel
                    } else {
                        iOS16TerminationNewsViewLabel.labelStyle(.titleOnly)
                    }
                }
            }
        }
        Section("新機能") {
            if needUseShiftKeySettingNews {
                IconNavigationLink("シフトキーが使えるようになりました！", systemImage: "shift", imageColor: .orange, destination: UseShiftKeyNews())
            }
            if needFlickDakutenKeyNews {
                IconNavigationLink("日本語フリックのカスタムキーで「濁点化」をサポート", systemImage: "bolt", imageColor: .orange, destination: FlickDakutenKeyNews())
            }
            if needUseFlickCustomSettingNews {
                IconNavigationLink("フリック式のカスタムタブが簡単に作れるようになりました！", systemImage: "wrench.adjustable", imageColor: .orange, destination: FlickCustardBaseSelectionNews())
            }
            IconNavigationLink("タブバーにアイコンを使えるようになりました！", systemImage: "heart.rectangle", imageColor: .orange, destination: TabBarSystemIconNews())
        }
    }
}
