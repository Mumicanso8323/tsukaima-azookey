//
//  VerticalCustomKeyboard.swift
//  azooKey
//
//  Created by ensan on 2021/02/18.
//  Copyright © 2021 ensan. All rights reserved.
//

import CustardKit
import Foundation
import SwiftUI

fileprivate extension CustardKeyLabelStyle {
    var keyLabelType: KeyLabelType {
        switch self {
        case let .text(value):
            return .text(value)
        case let .systemImage(value):
            return .image(value)
        case let .mainAndSub(main, sub):
            return .symbols([main, sub])
        }
    }
}

fileprivate extension CustardInterfaceLayoutScrollValue {
    var scrollDirection: Axis.Set {
        switch self.direction {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

fileprivate extension CustardInterfaceStyle {
    var keyboardLayout: KeyboardLayout {
        switch self {
        case .tenkeyStyle:
            return .flick
        case .pcStyle:
            return .qwerty
        }
    }
}

fileprivate extension CustardInterface {
    func tabDesign(interfaceSize: CGSize, keyboardOrientation: KeyboardOrientation) -> TabDependentDesign {
        switch self.keyLayout {
        case let .gridFit(value):
            return TabDependentDesign(width: value.rowCount, height: value.columnCount, interfaceSize: interfaceSize, orientation: keyboardOrientation)
        case let .gridScroll(value):
            switch value.direction {
            case .vertical:
                return TabDependentDesign(width: CGFloat(Int(value.rowCount)), height: CGFloat(value.columnCount), interfaceSize: interfaceSize, orientation: keyboardOrientation)
            case .horizontal:
                return TabDependentDesign(width: CGFloat(value.rowCount), height: CGFloat(Int(value.columnCount)), interfaceSize: interfaceSize, orientation: keyboardOrientation)
            }
        }
    }

    @MainActor func flickKeyModels<Extension: ApplicationSpecificKeyboardViewExtension>(extension _: Extension.Type) -> [(position: GridFitPositionSpecifier, model: any FlickKeyModelProtocol<Extension>)] {
        self.keys.reduce(into: []) {models, value in
            if case let .gridFit(data) = value.key {
                models.append((data, value.value.flickKeyModel(extension: Extension.self)))
            }
        }
    }

    @MainActor func qwertyKeyModels<Extension: ApplicationSpecificKeyboardViewExtension>(extension _: Extension.Type) -> [(position: QwertyPositionSpecifier, model: any QwertyKeyModelProtocol<Extension>)] {
        self.keys.reduce(into: []) {
            models,
            value in
            if case let .gridFit(data) = value.key {
                models.append(
                    (
                        .init(x: Double(data.x), y: Double(data.y), width: Double(data.width), height: Double(data.height)),
                        value.value.qwertyKeyModel(layout: self.keyLayout, extension: Extension.self)
                    )
                )
            }
        }
    }
}

fileprivate extension CustardKeyDesign.ColorType {
    var flickKeyBackgroundStyle: FlickKeyBackgroundStyle {
        switch self {
        case .normal:
            return .normal
        case .special:
            return .tabkey
        case .selected:
            return .selected
        case .unimportant:
            return .unimportant
        }
    }

    var qwertyKeyColorType: QwertyUnpressedKeyBackground {
        switch self {
        case .normal:
            return .normal
        case .special:
            return .special
        case .selected:
            return .selected
        case .unimportant:
            return .unimportant
        }
    }

    var simpleKeyColorType: SimpleUnpressedKeyColorType {
        switch self {
        case .normal:
            return .normal
        case .special:
            return .special
        case .selected:
            return .selected
        case .unimportant:
            return .unimportant
        }
    }

}

extension CustardInterfaceKey {
    @MainActor public func flickKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>(extension _: Extension.Type) -> any FlickKeyModelProtocol<Extension> {
        switch self {
        case let .system(value):
            switch value {
            case .changeKeyboard:
                return FlickChangeKeyboardModel.shared
            case .enter:
                return FlickEnterKeyModel()
            case .upperLower:
                return FlickAaKeyModel()
            case .nextCandidate:
                return FlickNextCandidateKeyModel.shared
            case .flickKogaki:
                return FlickKogakiKeyModel.shared
            case .flickKutoten:
                return FlickKanaSymbolsKeyModel.shared
            case .flickHiraTab:
                return FlickTabKeyModel.hiraTabKeyModel()
            case .flickAbcTab:
                return FlickTabKeyModel.abcTabKeyModel()
            case .flickStar123Tab:
                return FlickTabKeyModel.numberTabKeyModel()
            }
        case let .custom(value):
            let flickKeyModels: [FlickDirection: FlickedKeyModel] = value.variations.reduce(into: [:]) {dictionary, variation in
                switch variation.type {
                case let .flickVariation(direction):
                    dictionary[direction] = FlickedKeyModel(
                        labelType: variation.key.design.label.keyLabelType,
                        pressActions: variation.key.press_actions.map {$0.actionType},
                        longPressActions: variation.key.longpress_actions.longpressActionType
                    )
                case .longpressVariation:
                    break
                }
            }
            return FlickKeyModel(
                labelType: value.design.label.keyLabelType,
                pressActions: value.press_actions.map {$0.actionType},
                longPressActions: value.longpress_actions.longpressActionType,
                flickKeys: flickKeyModels,
                needSuggestView: value.longpress_actions == .none && !value.variations.isEmpty,
                keycolorType: value.design.color.flickKeyBackgroundStyle
            )
        }
    }

    private func convertToQwertyKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>(customKey: KeyFlickSetting.SettingData, extension _: Extension.Type) -> any QwertyKeyModelProtocol<Extension> {
        let variations = QwertyVariationsModel([customKey.flick[.left], customKey.flick[.top], customKey.flick[.right], customKey.flick[.bottom]].compactMap {$0}.map {(label: $0.labelType, actions: $0.pressActions)})
        return QwertyKeyModel(labelType: customKey.labelType, pressActions: customKey.actions, longPressActions: customKey.longpressActions, variationsModel: variations, keyColorType: .normal, needSuggestView: false)
    }

    @MainActor func qwertyKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>(layout: CustardInterfaceLayout, extension: Extension.Type) -> any QwertyKeyModelProtocol<Extension> {
        switch self {
        case let .system(value):
            switch value {
            case .changeKeyboard:
                return if let second = Extension.SettingProvider.preferredLanguage.second {
                    QwertyConditionalKeyModel(needSuggestView: false, unpressedKeyBackground: .special) { states in
                        if SemiStaticStates.shared.needsInputModeSwitchKey {
                            return QwertyChangeKeyboardKeyModel()
                        } else {
                            // 普通のキーで良い場合
                            let targetTab: TabData = switch second {
                            case .en_US:
                                .system(.user_english)
                            case .ja_JP, .none, .el_GR:
                                .system(.user_japanese)
                            }
                            return switch states.tabManager.existentialTab() {
                            case .qwerty_hira, .qwerty_abc:
                                QwertyFunctionalKeyModel(labelType: .text("#+="), pressActions: [.moveTab(.system(.qwerty_symbols))], longPressActions: .init(start: [.setTabBar(.toggle)]))
                            case .qwerty_numbers, .qwerty_symbols:
                                QwertyFunctionalKeyModel(labelType: .text(second.symbol), pressActions: [.moveTab(targetTab)])
                            default:
                                QwertyFunctionalKeyModel(labelType: .image("arrowtriangle.left.and.line.vertical.and.arrowtriangle.right"), pressActions: [.setCursorBar(.toggle)])
                            }
                        }
                    }
                } else {
                    QwertyConditionalKeyModel(needSuggestView: false, unpressedKeyBackground: .special) { _ in
                        if SemiStaticStates.shared.needsInputModeSwitchKey {
                            // 地球儀キーが必要な場合
                            QwertyChangeKeyboardKeyModel()
                        } else {
                            QwertyFunctionalKeyModel(labelType: .image("arrowtriangle.left.and.line.vertical.and.arrowtriangle.right"), pressActions: [.setCursorBar(.toggle)])
                        }
                    }
                }
            case .enter:
                return QwertyEnterKeyModel()
            case .upperLower:
                return QwertyAaKeyModel()
            case .nextCandidate:
                return QwertyNextCandidateKeyModel()
            case .flickKogaki:
                return convertToQwertyKeyModel(customKey: Extension.SettingProvider.koganaFlickCustomKey.compiled(), extension: Extension.self)
            case .flickKutoten:
                return convertToQwertyKeyModel(customKey: Extension.SettingProvider.kanaSymbolsFlickCustomKey.compiled(), extension: Extension.self)
            case .flickHiraTab:
                return convertToQwertyKeyModel(customKey: Extension.SettingProvider.hiraTabFlickCustomKey.compiled(), extension: Extension.self)
            case .flickAbcTab:
                return convertToQwertyKeyModel(customKey: Extension.SettingProvider.abcTabFlickCustomKey.compiled(), extension: Extension.self)
            case .flickStar123Tab:
                return convertToQwertyKeyModel(customKey: Extension.SettingProvider.symbolsTabFlickCustomKey.compiled(), extension: Extension.self)
            }
        case let .custom(value):
            let variations: [(label: KeyLabelType, actions: [ActionType])] = value.variations.reduce(into: []) {array, variation in
                switch variation.type {
                case .flickVariation:
                    break
                case .longpressVariation:
                    array.append((variation.key.design.label.keyLabelType, variation.key.press_actions.map {$0.actionType}))
                }
            }

            return QwertyKeyModel(
                labelType: value.design.label.keyLabelType,
                pressActions: value.press_actions.map {$0.actionType},
                longPressActions: value.longpress_actions.longpressActionType,
                variationsModel: QwertyVariationsModel(variations),
                keyColorType: value.design.color.qwertyKeyColorType,
                needSuggestView: value.longpress_actions == .none,
                )
        }
    }

    func simpleKeyModel<Extension: ApplicationSpecificKeyboardViewExtension>(extension _: Extension.Type) -> any SimpleKeyModelProtocol<Extension> {
        switch self {
        case let .system(value):
            switch value {
            case .changeKeyboard:
                return SimpleChangeKeyboardKeyModel()
            case .enter:
                return SimpleEnterKeyModel()
            case .upperLower:
                return SimpleKeyModel(keyLabelType: .text("a/A"), unpressedKeyColorType: .special, pressActions: [.changeCharacterType(.default)])
            case .nextCandidate:
                return SimpleNextCandidateKeyModel()
            case .flickKogaki:
                return SimpleKeyModel(keyLabelType: .text("小ﾞﾟ"), unpressedKeyColorType: .special, pressActions: [.changeCharacterType(.default)])
            case .flickKutoten:
                return SimpleKeyModel(keyLabelType: .text("、"), unpressedKeyColorType: .normal, pressActions: [.input("、")])
            case .flickHiraTab:
                return SimpleKeyModel(keyLabelType: .text("あいう"), unpressedKeyColorType: .special, pressActions: [.moveTab(.system(.user_japanese))])
            case .flickAbcTab:
                return SimpleKeyModel(keyLabelType: .text("ABC"), unpressedKeyColorType: .special, pressActions: [.moveTab(.system(.user_english))])
            case .flickStar123Tab:
                return SimpleKeyModel(keyLabelType: .text("☆123"), unpressedKeyColorType: .special, pressActions: [.moveTab(.system(.flick_numbersymbols))])
            }
        case let .custom(value):
            return SimpleKeyModel(
                keyLabelType: value.design.label.keyLabelType,
                unpressedKeyColorType: value.design.color.simpleKeyColorType,
                pressActions: value.press_actions.map {$0.actionType},
                longPressActions: value.longpress_actions.longpressActionType
            )
        }
    }
}

@MainActor
struct CustomKeyboardView<Extension: ApplicationSpecificKeyboardViewExtension>: View {
    private let custard: Custard
    private var tabDesign: TabDependentDesign {
        custard.interface.tabDesign(interfaceSize: variableStates.interfaceSize, keyboardOrientation: variableStates.keyboardOrientation)
    }
    @EnvironmentObject private var variableStates: VariableStates

    init(custard: Custard) {
        self.custard = custard
    }

    var body: some View {
        switch custard.interface.keyLayout {
        case let .gridFit(value):
            switch custard.interface.keyStyle {
            case .tenkeyStyle:
                CustardFlickKeysView(models: custard.interface.flickKeyModels(extension: Extension.self), tabDesign: tabDesign, layout: value) {(view: FlickKeyView<Extension>, _, _) in
                    view
                }
            case .pcStyle:
                let models = custard.interface.qwertyKeyModels(extension: Extension.self)
                CustardQwertyKeysView(models: models, tabDesign: tabDesign, layout: value) { (view, _) in
                    view
                }
            }
        case let .gridScroll(value):
            let models = (0..<custard.interface.keys.count).compactMap { index in
                (custard.interface.keys[.gridScroll(GridScrollPositionSpecifier(index))]).map {($0, index)}
            }
            CustardScrollKeysView<Extension, Int, _>(models: models, tabDesign: tabDesign, layout: value) { (view, _) in
                view
            }
        }
    }
}

public struct CustardScrollKeysView<Extension: ApplicationSpecificKeyboardViewExtension, ID: Hashable, Content: View>: View {
    public init(models: [(CustardInterfaceKey, ID)], tabDesign: TabDependentDesign, layout: CustardInterfaceLayoutScrollValue, @ViewBuilder generator: @escaping (_ view: SimpleKeyView<Extension>, _ id: ID) -> (Content)) {
        self.models = models
        self.tabDesign = tabDesign
        self.layout = layout
        self.contentGenerator = generator
    }

    private let contentGenerator: (_ view: SimpleKeyView<Extension>, _ id: ID) -> (Content)
    private let models: [(CustardInterfaceKey, ID)]
    private let tabDesign: TabDependentDesign
    private let layout: CustardInterfaceLayoutScrollValue

    public var body: some View {
        let height = tabDesign.keysHeight
        switch layout.direction {
        case .vertical:
            let gridItem = GridItem(.fixed(tabDesign.keyViewWidth), spacing: tabDesign.horizontalSpacing / 2)
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: gridItem, count: Int(layout.rowCount)), spacing: tabDesign.verticalSpacing / 2) {
                    ForEach(models, id: \.1) {(model, id) in
                        contentGenerator(
                            SimpleKeyView<Extension>(
                                model: model.simpleKeyModel(extension: Extension.self),
                                tabDesign: tabDesign
                            ),
                            id
                        )
                    }
                }
            }.frame(height: height)
        case .horizontal:
            let gridItem = GridItem(.fixed(tabDesign.keyViewHeight), spacing: tabDesign.verticalSpacing / 2)
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: gridItem, count: Int(layout.columnCount)), spacing: tabDesign.horizontalSpacing / 2) {
                    ForEach(models, id: \.1) {(model, id) in
                        contentGenerator(
                            SimpleKeyView<Extension>(
                                model: model.simpleKeyModel(extension: Extension.self),
                                tabDesign: tabDesign
                            ),
                            id
                        )
                    }
                }
            }.frame(height: height)
        }
    }
}

public struct CustardFlickKeysView<Extension: ApplicationSpecificKeyboardViewExtension, Content: View>: View {
    @State private var suggestState = FlickSuggestState()

    public init(models: [(position: GridFitPositionSpecifier, model: any FlickKeyModelProtocol<Extension>)], tabDesign: TabDependentDesign, layout: CustardInterfaceLayoutGridValue, blur: Bool = false, @ViewBuilder generator: @escaping (FlickKeyView<Extension>, Int, Int) -> (Content)) {
        self.models = models.filter { $0.position.x < layout.rowCount && $0.position.y < layout.columnCount }
        self.tabDesign = tabDesign
        self.layout = layout
        self.blur = blur
        self.contentGenerator = generator
    }

    private let contentGenerator: (FlickKeyView<Extension>, Int, Int) -> (Content)
    private let models: [(position: GridFitPositionSpecifier, model: any FlickKeyModelProtocol<Extension>)]
    private let tabDesign: TabDependentDesign
    private let layout: CustardInterfaceLayoutGridValue
    private let blur: Bool

    @MainActor private func flickKeyData(x: Int, y: Int, width: CGFloat, height: CGFloat) -> (position: CGPoint, size: CGSize, contentSize: CGSize) {
        let width = tabDesign.keyViewWidth(widthCount: width)
        let height = tabDesign.keyViewHeight(heightCount: height)
        let dx = width * 0.5 + tabDesign.keyViewWidth * CGFloat(x) + tabDesign.horizontalSpacing * CGFloat(x)
        let dy = height * 0.5 + tabDesign.keyViewHeight * CGFloat(y) + tabDesign.verticalSpacing * CGFloat(y)
        let contentWidth = width + tabDesign.horizontalSpacing
        let contentHeight = height + tabDesign.verticalSpacing
        return (CGPoint(x: dx, y: dy), CGSize(width: width, height: height), CGSize(width: contentWidth, height: contentHeight))
    }

    public var body: some View {
        ZStack {
            ForEach(models, id: \.position) { item in
                let x = item.position.x
                let y = item.position.y
                let suggestState = self.suggestState.items[x, default: [:]][y]
                let info = flickKeyData(x: x, y: y, width: Double(item.position.width), height: Double(item.position.height))
                contentGenerator(FlickKeyView(model: item.model, size: info.size, position: (x, y), suggestState: $suggestState), x, y)
                    .zIndex(suggestState != nil ? 1 : 0)
                    .overlay(alignment: .center) {
                        if let suggestState {
                            FlickSuggestView<Extension>(model: item.model, tabDesign: tabDesign, size: info.size, suggestType: suggestState)
                                .zIndex(2)
                        }
                    }
                    .frame(width: info.contentSize.width, height: info.contentSize.height)
                    .contentShape(Rectangle())
                    .position(x: info.position.x, y: info.position.y)
            }
        }
        .frame(width: tabDesign.keysWidth, height: tabDesign.keysHeight)
    }
}

public enum GridKeySizeOffset {
    case fraction(x: CGFloat, y: CGFloat)
}

public struct CustardQwertyKeysView<Extension: ApplicationSpecificKeyboardViewExtension, Content: View>: View {
    @State private var suggestState = QwertySuggestState()

    public init(models: [(position: QwertyPositionSpecifier, model: any QwertyKeyModelProtocol<Extension>)], tabDesign: TabDependentDesign, layout: CustardInterfaceLayoutGridValue, @ViewBuilder generator: @escaping (QwertyKeyView<Extension>, QwertyPositionSpecifier) -> (Content)) {
        self.models = models.filter { $0.position.x < Double(layout.rowCount) && $0.position.y < Double(layout.columnCount) }
        self.tabDesign = tabDesign
        self.layout = layout
        self.contentGenerator = generator
    }

    private let contentGenerator: (QwertyKeyView<Extension>, QwertyPositionSpecifier) -> (Content)
    private let models: [(position: QwertyPositionSpecifier, model: any QwertyKeyModelProtocol<Extension>)]
    private let tabDesign: TabDependentDesign
    private let layout: CustardInterfaceLayoutGridValue

    @MainActor private func qwertyKeyData(position: QwertyPositionSpecifier) -> (position: CGPoint, size: CGSize, contentSize: CGSize) {
        let width = tabDesign.keyViewWidth(widthCount: CGFloat(position.width))
        let height = tabDesign.keyViewHeight(heightCount: CGFloat(position.height))
        let x = position.x
        let y = position.y
        let dx = width * 0.5 + tabDesign.keyViewWidth * x + tabDesign.horizontalSpacing * x
        let dy = height * 0.5 + tabDesign.keyViewHeight * y + tabDesign.verticalSpacing * y
        let contentWidth = width + tabDesign.horizontalSpacing
        let contentHeight = height + tabDesign.verticalSpacing
        return (CGPoint(x: dx, y: dy), CGSize(width: width, height: height), CGSize(width: contentWidth, height: contentHeight))
    }

    public var body: some View {
        ZStack {
            ForEach(models, id: \.position) {item in
                let suggestState = self.suggestState[item.position]
                let info = qwertyKeyData(position: item.position)
                contentGenerator(QwertyKeyView<Extension>(model: item.model, tabDesign: tabDesign, size: info.size, suggestType: $suggestState[item.position]), item.position)
                    .zIndex(suggestState != nil ? 1 : 0)
                    .overlay(alignment: .bottom) {
                        if let suggestState {
                            QwertySuggestView<Extension>(model: item.model, tabDesign: tabDesign, size: info.size, suggestType: suggestState)
                                .zIndex(2)
                        }
                    }
                    .frame(width: info.contentSize.width, height: info.contentSize.height)
                    .contentShape(Rectangle())
                    .position(x: info.position.x, y: info.position.y)
            }
        }
        .frame(width: tabDesign.keysWidth, height: tabDesign.keysHeight)
    }
}
