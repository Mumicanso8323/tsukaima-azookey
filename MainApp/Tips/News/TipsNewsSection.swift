//
//  TipsNewsSection.swift
//  azooKey
//
//  Created by miwa on 2023/11/11.
//  Copyright © 2023 DevEn3. All rights reserved.
//

import SwiftUI

struct TipsNewsSection: View {
    @AppStorage("read_article_iOS16_service_termination") private var readArticle_iOS16_service_termination = false
    @AppStorage("read_terms_of_use_update_2025_05_31") private var readTermsOfUseUpdate_2025_05_31 = false
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

    private var iOS16TerminationNewsViewLabel: some View {
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
                NavigationLink {
                    iOS16TerminationNewsView($readArticle_iOS16_service_termination)
                } label: {
                    if !readArticle_iOS16_service_termination {
                        iOS16TerminationNewsViewLabel
                    } else {
                        iOS16TerminationNewsViewLabel.labelStyle(.titleOnly)
                    }
                }
            }
        }
        if !readArticle_iOS16_service_termination {
            Section("利用規約の更新") {
                NavigationLink {
                    TermsOfServiceUpdateNews(readTermsOfUseUpdate_2025_05_31: $readTermsOfUseUpdate_2025_05_31)
                } label: {
                    Label(
                        title: {
                            Text("利用規約を更新しました")
                        },
                        icon: {
                            Image(systemName: "bell.badge")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    )
                }
            }
        }
        Section("新機能") {
            if needUseShiftKeySettingNews {
                IconNavigationLink("シフトキーが使えるようになりました！", systemImage: "shift", imageColor: .orange) {
                    UseShiftKeyNews()
                }
            }
            if needFlickDakutenKeyNews {
                IconNavigationLink("日本語フリックのカスタムキーで「濁点化」をサポート", systemImage: "bolt", imageColor: .orange) {
                    FlickDakutenKeyNews()
                }
            }
            if needUseFlickCustomSettingNews {
                IconNavigationLink("フリック式のカスタムタブが簡単に作れるようになりました！", systemImage: "wrench.adjustable", imageColor: .orange) {
                    FlickCustardBaseSelectionNews()
                }
            }
            IconNavigationLink("タブバーにアイコンを使えるようになりました！", systemImage: "heart.rectangle", imageColor: .orange) {
                TabBarSystemIconNews()
            }
        }
    }
}
