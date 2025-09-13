import Foundation
import KeyboardThemes
import SwiftUI

struct QwertySpaceKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>: UnifiedKeyModelProtocol {
    @MainActor func showsTapBubble(variableStates _: VariableStates) -> Bool { false }

    func pressActions(variableStates _: VariableStates) -> [ActionType] { [.input(" ")] }
    func longPressActions(variableStates _: VariableStates) -> LongpressActionType { .init(start: [.setCursorBar(.toggle)]) }
    func doublePressActions(variableStates _: VariableStates) -> [ActionType] { [] }
    func variationSpace(variableStates _: VariableStates) -> UnifiedVariationSpace { .none }

    func label<ThemeExtension>(width: CGFloat, theme _: ThemeData<ThemeExtension>, states: VariableStates, color: Color?) -> KeyLabel<Extension> where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        switch states.keyboardLanguage {
        case .el_GR:
            return KeyLabel(.text("διάστημα"), width: width, textSize: .small, textColor: color)
        case .en_US:
            return KeyLabel(.text("space"), width: width, textSize: .small, textColor: color)
        case .ja_JP, .none:
            return KeyLabel(.text("空白"), width: width, textSize: .small, textColor: color)
        }
    }

    func backgroundStyleWhenPressed<ThemeExtension>(theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        (theme.pushedKeyFillColor.color, theme.pushedKeyFillColor.blendMode)
    }
    func backgroundStyleWhenUnpressed<ThemeExtension>(states _: VariableStates, theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        (theme.normalKeyFillColor.color, theme.normalKeyFillColor.blendMode)
    }
    func feedback(variableStates _: VariableStates) { KeyboardFeedback<Extension>.click() }
}
