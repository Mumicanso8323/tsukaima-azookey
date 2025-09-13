import Foundation
import KeyboardThemes
import SwiftUI

struct UnifiedEnterKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>: UnifiedKeyModelProtocol {
    @MainActor func showsTapBubble(variableStates _: VariableStates) -> Bool { false }
    // Qwertyでは小さめの文字、Flickでは既定サイズを使う。nilの場合はデフォルトサイズ。
    private let textSize: Design.Fonts.LabelFontSizeStrategy

    init(textSize: Design.Fonts.LabelFontSizeStrategy = .small) {
        self.textSize = textSize
    }

    func pressActions(variableStates: VariableStates) -> [ActionType] {
        switch variableStates.enterKeyState {
        case .complete:
            return [.enter]
        case .return:
            return [.input("\n")]
        }
    }

    func longPressActions(variableStates _: VariableStates) -> LongpressActionType { .none }
    func doublePressActions(variableStates _: VariableStates) -> [ActionType] { [] }

    func variationSpace(variableStates _: VariableStates) -> UnifiedVariationSpace { .none }

    private func specialTextColor<ThemeExtension: ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable>(states: VariableStates, theme: ThemeData<ThemeExtension>) -> Color? {
        switch states.enterKeyState {
        case .complete:
            return nil
        case let .return(type):
            switch type {
            case .default:
                return nil
            default:
                if theme == ThemeExtension.native {
                    return .white
                } else {
                    return nil
                }
            }
        }
    }

    func label<ThemeExtension>(width: CGFloat, theme: ThemeData<ThemeExtension>, states: VariableStates, color: Color?) -> KeyLabel<Extension> where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        let text = Design.language.getEnterKeyText(states.enterKeyState)
        return KeyLabel(.text(text), width: width, textSize: textSize, textColor: color ?? specialTextColor(states: states, theme: theme))
    }

    func backgroundStyleWhenPressed<ThemeExtension>(theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        (theme.pushedKeyFillColor.color, theme.pushedKeyFillColor.blendMode)
    }

    func backgroundStyleWhenUnpressed<ThemeExtension>(states: VariableStates, theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        switch states.enterKeyState {
        case .complete:
            return (theme.specialKeyFillColor.color, theme.specialKeyFillColor.blendMode)
        case let .return(type):
            switch type {
            case .default:
                return (theme.specialKeyFillColor.color, theme.specialKeyFillColor.blendMode)
            default:
                if theme == ThemeExtension.default {
                    return (Design.colors.specialEnterKeyColor, .normal)
                } else if theme == ThemeExtension.native {
                    return (.accentColor, .normal)
                } else {
                    return (theme.specialKeyFillColor.color, theme.specialKeyFillColor.blendMode)
                }
            }
        }
    }

    func feedback(variableStates: VariableStates) {
        switch variableStates.enterKeyState {
        case .complete:
            KeyboardFeedback<Extension>.tabOrOtherKey()
        case let .return(type):
            switch type {
            case .default:
                KeyboardFeedback<Extension>.click()
            default:
                KeyboardFeedback<Extension>.tabOrOtherKey()
            }
        }
    }
}
