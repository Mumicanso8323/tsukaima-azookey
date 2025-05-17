//
//  QwertyKeyModelProtocol.swift
//  Keyboard
//
//  Created by ensan on 2020/09/18.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation
import KeyboardThemes
import SwiftUI

public typealias QwertyKeyBackgroundStyleValue = (color: Color, blendMode: BlendMode)

extension ThemeColor {
    var qwertyKeyBackgroundStyle: QwertyKeyBackgroundStyleValue {
        (self.color, self.blendMode)
    }
}

public struct QwertyPositionSpecifier: Sendable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double = 1
    var height: Double = 1
}

public enum QwertyUnpressedKeyBackground: Sendable {
    case normal
    case special
    case enter
    case selected
    case unimportant

    func color<ThemeExtension: ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable>(states: VariableStates, theme: ThemeData<ThemeExtension>) -> QwertyKeyBackgroundStyleValue {
        switch self {
        case .normal:
            theme.normalKeyFillColor.qwertyKeyBackgroundStyle
        case .special:
            theme.specialKeyFillColor.qwertyKeyBackgroundStyle
        case .selected:
            theme.pushedKeyFillColor.qwertyKeyBackgroundStyle
        case .unimportant:
            (Color(white: 0, opacity: 0.001), .normal)
        case .enter:
            switch states.enterKeyState {
            case .complete:
                theme.specialKeyFillColor.qwertyKeyBackgroundStyle
            case let .return(type):
                switch type {
                case .default:
                    theme.specialKeyFillColor.qwertyKeyBackgroundStyle
                default:
                    if theme == ThemeExtension.default(layout: .qwerty) {
                        (Design.colors.specialEnterKeyColor, .normal)
                    } else if theme == ThemeExtension.native() {
                        (.accentColor, .normal)
                    } else {
                        theme.specialKeyFillColor.qwertyKeyBackgroundStyle
                    }
                }
            }
        }
    }
}

public protocol QwertyKeyModelProtocol<Extension> {
    associatedtype Extension: ApplicationSpecificKeyboardViewExtension

    var needSuggestView: Bool {get}

    var variationsModel: QwertyVariationsModel {get}

    @MainActor func pressActions(variableStates: VariableStates) -> [ActionType]
    @MainActor func longPressActions(variableStates: VariableStates) -> LongpressActionType
    /// 二回連続で押した際に発火するActionを指定する
    @MainActor func doublePressActions(variableStates: VariableStates) -> [ActionType]
    @MainActor func label<ThemeExtension: ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable>(width: CGFloat, theme: ThemeData<ThemeExtension>, states: VariableStates, color: Color?) -> KeyLabel<Extension>
    func backgroundStyleWhenPressed(theme: Extension.Theme) -> QwertyKeyBackgroundStyleValue
    var unpressedKeyBackground: QwertyUnpressedKeyBackground {get}

    @MainActor func feedback(variableStates: VariableStates)
}

extension QwertyKeyModelProtocol {
    func backgroundStyleWhenPressed(theme: ThemeData<some ApplicationSpecificTheme>) -> QwertyKeyBackgroundStyleValue {
        theme.pushedKeyFillColor.qwertyKeyBackgroundStyle
    }
    func doublePressActions(variableStates _: VariableStates) -> [ActionType] {
        []
    }
}
