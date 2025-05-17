//
//  VerticalQwertyKeyboardView.swift
//  Keyboard
//
//  Created by ensan on 2020/09/18.
//  Copyright © 2020 ensan. All rights reserved.
//

import CustardKit
import Foundation
import SwiftUI

struct QwertyKeyboardView<Extension: ApplicationSpecificKeyboardViewExtension>: View {
    private let tabDesign: TabDependentDesign
    private let models: [(
        position: QwertyPositionSpecifier,
        model: any QwertyKeyModelProtocol<Extension>
    )]

    init(keyModels: [QwertyPositionSpecifier: any QwertyKeyModelProtocol<Extension>], interfaceSize: CGSize, keyboardOrientation: KeyboardOrientation) {
        self.tabDesign = TabDependentDesign(width: 10, height: 4, interfaceSize: interfaceSize, orientation: keyboardOrientation)

        var models: [(QwertyPositionSpecifier, any QwertyKeyModelProtocol<Extension>)] = []
        for (pos, model) in keyModels {
            models.append((pos, model))
        }
        self.models = models
    }

    var body: some View {
        let layout = CustardInterfaceLayoutGridValue(rowCount: Int(tabDesign.horizontalKeyCount), columnCount: Int(tabDesign.verticalKeyCount))
        CustardQwertyKeysView(models: models, tabDesign: tabDesign, layout: layout) {(view: QwertyKeyView<Extension>, _) in
            view
        }
    }
}
