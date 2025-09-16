import Foundation
import KeyboardThemes
import SwiftUI
import CustardKit
import enum KanaKanjiConverterModule.KeyboardLanguage

struct QwertyDynamicChangeKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>: UnifiedKeyModelProtocol {
    func pressActions(variableStates states: VariableStates) -> [ActionType] {
        if SemiStaticStates.shared.needsInputModeSwitchKey {
            switch states.tabManager.existentialTab() {
            case .qwerty_abc:
                if QwertyLayoutProvider<Extension>.shiftBehaviorPreference() != .leftbottom || states.boolStates.isShifted || states.boolStates.isCapsLocked {
                    return [] // system globe
                } else {
                    return [.moveTab(.system(.qwerty_numbers))]
                }
            default:
                return [] // system globe
            }
        } else {
            let preferred = Extension.SettingProvider.preferredLanguage
            let targetTab: TabData = switch preferred.second ?? .ja_JP {
            case .en_US: .system(.user_english)
            case .ja_JP, .none, .el_GR: .system(.user_japanese)
            }

            switch states.tabManager.existentialTab() {
            case .qwerty_hira:
                return [.moveTab(.system(.qwerty_symbols))]
            case .qwerty_abc:
                if QwertyLayoutProvider<Extension>.shiftBehaviorPreference() != .leftbottom || states.boolStates.isShifted || states.boolStates.isCapsLocked {
                    return [.moveTab(.system(.qwerty_symbols))]
                } else {
                    return [.moveTab(.system(.qwerty_numbers))]
                }
            case .qwerty_numbers, .qwerty_symbols:
                return [.moveTab(targetTab)]
            default:
                return [.setCursorBar(.toggle)]
            }
        }
    }

    func longPressActions(variableStates: VariableStates) -> LongpressActionType {
        if QwertyLayoutProvider<Extension>.shiftBehaviorPreference() != .leftbottom || variableStates.boolStates.isShifted || variableStates.boolStates.isCapsLocked {
            .none
        } else {
            .init(start: [.setTabBar(.toggle)])
        }
    }
    func variationSpace(variableStates _: VariableStates) -> UnifiedVariationSpace { .none }

    func label<ThemeExtension>(width: CGFloat, theme _: ThemeData<ThemeExtension>, states: VariableStates, color: Color?) -> KeyLabel<Extension> where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        if SemiStaticStates.shared.needsInputModeSwitchKey {
            switch states.tabManager.existentialTab() {
            case .qwerty_abc:
                if QwertyLayoutProvider<Extension>.shiftBehaviorPreference() != .leftbottom || states.boolStates.isShifted || states.boolStates.isCapsLocked {
                    return KeyLabel(.changeKeyboard, width: width, textColor: color)
                } else {
                    return KeyLabel(.image("textformat.123"), width: width, textColor: color)
                }
            default:
                return KeyLabel(.changeKeyboard, width: width, textColor: color)
            }
        } else {
            let preferred = Extension.SettingProvider.preferredLanguage
            switch states.tabManager.existentialTab() {
            case .qwerty_hira:
                return KeyLabel(.text("#+="), width: width, textColor: color)
            case .qwerty_abc:
                if QwertyLayoutProvider<Extension>.shiftBehaviorPreference() != .leftbottom || states.boolStates.isShifted || states.boolStates.isCapsLocked {
                    return KeyLabel(.text("#+="), width: width, textColor: color)
                } else {
                    return KeyLabel(.image("textformat.123"), width: width, textColor: color)
                }
            case .qwerty_numbers, .qwerty_symbols:
                if let second = preferred.second {
                    return KeyLabel(.text(second.symbol), width: width, textColor: color)
                } else {
                    return KeyLabel(.text(preferred.first.symbol), width: width, textColor: color)
                }
            default:
                return KeyLabel(.image("arrowtriangle.left.and.line.vertical.and.arrowtriangle.right"), width: width, textColor: color)
            }
        }
    }
    func backgroundStyleWhenUnpressed<ThemeExtension>(states _: VariableStates, theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        (theme.specialKeyFillColor.color, theme.specialKeyFillColor.blendMode)
    }
    func feedback(variableStates _: VariableStates) {
        KeyboardFeedback<Extension>.tabOrOtherKey()
    }
}
