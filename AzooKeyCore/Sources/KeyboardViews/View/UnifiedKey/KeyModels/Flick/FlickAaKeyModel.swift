import Foundation
import KeyboardThemes
import SwiftUI
import CustardKit

struct FlickAaKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>: UnifiedKeyModelProtocol {
    @MainActor func showsTapBubble(variableStates _: VariableStates) -> Bool { false }
    func pressActions(variableStates: VariableStates) -> [ActionType] {
        if variableStates.boolStates.isCapsLocked {
            [.setBoolState(VariableStates.BoolStates.isCapsLockedKey, .off)]
        } else {
            [.changeCharacterType(.default)]
        }
    }
    func longPressActions(variableStates _: VariableStates) -> LongpressActionType { .none }
    func doublePressActions(variableStates _: VariableStates) -> [ActionType] { [] }

    func variationSpace(variableStates: VariableStates) -> UnifiedVariationSpace {
        if variableStates.boolStates.isCapsLocked {
            .none
        } else {
            .fourWay([.top: UnifiedVariation(label: .image("capslock"), pressActions: [.setBoolState(VariableStates.BoolStates.isCapsLockedKey, .on)])])
        }
    }

    func isFlickAble(to direction: FlickDirection, variableStates: VariableStates) -> Bool {
        !variableStates.boolStates.isCapsLocked && direction == .top
    }
    func flickSensitivity(to direction: FlickDirection) -> CGFloat { 25 / Extension.SettingProvider.flickSensitivity }
    func label<ThemeExtension>(width: CGFloat, theme _: ThemeData<ThemeExtension>, states: VariableStates, color _: Color?) -> KeyLabel<Extension> where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        if states.boolStates.isCapsLocked {
            KeyLabel(.image("capslock.fill"), width: width)
        } else {
            KeyLabel(.text("a/A"), width: width)
        }
    }
    func backgroundStyleWhenPressed<ThemeExtension>(theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable { (theme.pushedKeyFillColor.color, theme.pushedKeyFillColor.blendMode) }
    func backgroundStyleWhenUnpressed<ThemeExtension>(states: VariableStates, theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        if states.boolStates.isCapsLocked {
            (theme.specialKeyFillColor.color, theme.specialKeyFillColor.blendMode)
        } else {
            (theme.normalKeyFillColor.color, theme.normalKeyFillColor.blendMode)
        }
    }
    func feedback(variableStates _: VariableStates) {
        KeyboardFeedback<Extension>.tabOrOtherKey()
    }
}
