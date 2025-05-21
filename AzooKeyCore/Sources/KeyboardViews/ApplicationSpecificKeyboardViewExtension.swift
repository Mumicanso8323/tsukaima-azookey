//
//  ApplicationSpecificKeyboardViewExtension.swift
//
//
//  Created by ensan on 2023/07/21.
//

import Foundation
import KeyboardThemes

public protocol ApplicationSpecificKeyboardViewExtension {
    associatedtype ThemeExtension: ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable
    associatedtype MessageProvider: ApplicationSpecificKeyboardViewMessageProvider
    associatedtype SettingProvider: ApplicationSpecificKeyboardViewSettingProvider
}

public extension ApplicationSpecificKeyboardViewExtension {
    typealias Theme = ThemeData<ThemeExtension>
}

public protocol ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable: ApplicationSpecificTheme {
    /// アプリケーションデフォルト
    static func `default`(layout: KeyboardLayout) -> ThemeData<Self>
    /// ネイティブデザイン
    static func native() -> ThemeData<Self>
}

public protocol ApplicationSpecificKeyboardViewMessageProvider {
    associatedtype MessageID: MessageIdentifierProtocol
    static var messages: [MessageData<MessageID>] { get }
    static var userDefaults: UserDefaults { get }
}
