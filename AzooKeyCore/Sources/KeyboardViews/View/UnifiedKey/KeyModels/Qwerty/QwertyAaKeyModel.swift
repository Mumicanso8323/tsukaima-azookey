import Foundation
import KeyboardThemes
import SwiftUI

struct QwertyAaKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>: UnifiedKeyModelProtocol {
    @MainActor func showsTapBubble(variableStates _: VariableStates) -> Bool { false }

    func pressActions(variableStates: VariableStates) -> [ActionType] {
        if variableStates.boolStates.isCapsLocked {
            return [.setBoolState(VariableStates.BoolStates.isCapsLockedKey, .off)]
        } else {
            return [.changeCharacterType(.default)]
        }
    }
    func longPressActions(variableStates _: VariableStates) -> LongpressActionType { .init(start: [.setBoolState(VariableStates.BoolStates.isCapsLockedKey, .toggle)]) }
    func doublePressActions(variableStates _: VariableStates) -> [ActionType] { [] }
    func variationSpace(variableStates _: VariableStates) -> UnifiedVariationSpace { .none }

    func label<ThemeExtension>(width: CGFloat, theme _: ThemeData<ThemeExtension>, states: VariableStates, color: Color?) -> KeyLabel<Extension> where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        if states.boolStates.isCapsLocked {
            KeyLabel(.image("capslock.fill"), width: width, textColor: color)
        } else {
            KeyLabel(.text("Aa"), width: width, textColor: color)
        }
    }
    func backgroundStyleWhenPressed<ThemeExtension>(theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable { (theme.pushedKeyFillColor.color, theme.pushedKeyFillColor.blendMode) }
    func backgroundStyleWhenUnpressed<ThemeExtension>(states _: VariableStates, theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable { (theme.specialKeyFillColor.color, theme.specialKeyFillColor.blendMode) }
    func feedback(variableStates _: VariableStates) { KeyboardFeedback<Extension>.tabOrOtherKey() }
}
