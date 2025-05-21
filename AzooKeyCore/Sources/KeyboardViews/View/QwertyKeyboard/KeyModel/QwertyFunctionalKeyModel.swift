//
//  QwertyFunctionalKeyModel.swift
//  Keyboard
//
//  Created by ensan on 2020/09/18.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation
import KeyboardThemes
import SwiftUI

struct QwertyFunctionalKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>: QwertyKeyModelProtocol {
    static var delete: Self { QwertyFunctionalKeyModel(labelType: .image("delete.left"), pressActions: [.delete(1)], longPressActions: .init(repeat: [.delete(1)])) }

    private let pressActions: [ActionType]
    var longPressActions: LongpressActionType
    /// 暫定
    let variationsModel = QwertyVariationsModel([])

    let labelType: KeyLabelType
    let needSuggestView: Bool
    let unpressedKeyBackground: QwertyUnpressedKeyBackground = .special

    init(labelType: KeyLabelType, pressActions: [ActionType], longPressActions: LongpressActionType = .none, needSuggestView: Bool = false) {
        self.labelType = labelType
        self.pressActions = pressActions
        self.longPressActions = longPressActions
        self.needSuggestView = needSuggestView
    }

    func pressActions(variableStates: VariableStates) -> [ActionType] {
        self.pressActions
    }

    func longPressActions(variableStates _: VariableStates) -> LongpressActionType {
        self.longPressActions
    }

    func label<ThemeExtension: ApplicationSpecificKeyboardViewExtensionLayoutDependentDefaultThemeProvidable>(width: CGFloat, theme: ThemeData<ThemeExtension>, states: VariableStates, color: Color?) -> KeyLabel<Extension> {
        KeyLabel(self.labelType, width: width, textColor: color)
    }

    func feedback(variableStates: VariableStates) {
        self.pressActions.first?.feedback(variableStates: variableStates, extension: Extension.self)
    }

}
