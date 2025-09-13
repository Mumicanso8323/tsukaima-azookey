import CustardKit
import Foundation
import KeyboardThemes
import SwiftUI

struct FlickChangeKeyboardKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>: UnifiedKeyModelProtocol {
    // We don't need .all suggest for this key; per-direction suggest appears on movement.
    @MainActor func showsTapBubble(variableStates _: VariableStates) -> Bool { false }

    func pressActions(variableStates _: VariableStates) -> [ActionType] {
        SemiStaticStates.shared.needsInputModeSwitchKey ? [] : [.setCursorBar(.toggle)]
    }
    func longPressActions(variableStates _: VariableStates) -> LongpressActionType { .none }
    func doublePressActions(variableStates _: VariableStates) -> [ActionType] { [] }
    func variationSpace(variableStates: VariableStates) -> UnifiedVariationSpace {
        let usePasteButton = (!SemiStaticStates.shared.needsInputModeSwitchKey &&
                              SemiStaticStates.shared.hasFullAccess &&
                              Extension.SettingProvider.enablePasteButton)
        if usePasteButton {
            return .fourWay([.top: UnifiedVariation(label: .image("doc.on.clipboard"), pressActions: [.paste])])
        }
        return .none
    }
    func isFlickAble(to direction: FlickDirection, variableStates _: VariableStates) -> Bool {
        let usePasteButton = (!SemiStaticStates.shared.needsInputModeSwitchKey &&
                              SemiStaticStates.shared.hasFullAccess &&
                              Extension.SettingProvider.enablePasteButton)
        return direction == .top && usePasteButton
    }
    func flickSensitivity(to direction: FlickDirection) -> CGFloat { 25 / Extension.SettingProvider.flickSensitivity }
    func label<ThemeExtension>(width: CGFloat, theme _: ThemeData<ThemeExtension>, states _: VariableStates, color _: Color?) -> KeyLabel<Extension> where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        SemiStaticStates.shared.needsInputModeSwitchKey ? KeyLabel(.changeKeyboard, width: width) : KeyLabel(.image("arrowtriangle.left.and.line.vertical.and.arrowtriangle.right"), width: width)
    }
    func backgroundStyleWhenPressed<ThemeExtension>(theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        (theme.pushedKeyFillColor.color, theme.pushedKeyFillColor.blendMode)
    }
    func backgroundStyleWhenUnpressed<ThemeExtension>(states _: VariableStates, theme: ThemeData<ThemeExtension>) -> UnifiedKeyBackgroundStyleValue where ThemeExtension : ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable {
        (theme.specialKeyFillColor.color, theme.specialKeyFillColor.blendMode)
    }
    func feedback(variableStates _: VariableStates) {
        KeyboardFeedback<Extension>.tabOrOtherKey()
    }
}
