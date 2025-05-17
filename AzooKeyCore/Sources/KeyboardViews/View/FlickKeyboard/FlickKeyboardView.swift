//
//  FlickKeyboardView.swift
//  Keyboard
//
//  Created by ensan on 2020/04/16.
//  Copyright © 2020 ensan. All rights reserved.
//

import CustardKit
import Foundation
import SwiftUI

struct FlickKeyboardView<Extension: ApplicationSpecificKeyboardViewExtension>: View {
    @State private var suggestState = FlickSuggestState()

    private let tabDesign: TabDependentDesign
    private let models: [(position: GridFitPositionSpecifier, model: any FlickKeyModelProtocol<Extension>)]
    init(keyModels: [[any FlickKeyModelProtocol<Extension>]], interfaceSize: CGSize, keyboardOrientation: KeyboardOrientation) {
        self.tabDesign = TabDependentDesign(width: 5, height: 4, interfaceSize: interfaceSize, orientation: keyboardOrientation)
        var models: [(position: GridFitPositionSpecifier, model: any FlickKeyModelProtocol<Extension>)] = []
        for h in keyModels.indices {
            for v in keyModels[h].indices {
                let model = keyModels[h][v]
                let position: GridFitPositionSpecifier = .init(x: h, y: v, width: 1, height: model is FlickEnterKeyModel<Extension> ? 2 : 1)
                models.append((position, model))
            }
        }
        self.models = models
    }

    var body: some View {
        let layout = CustardInterfaceLayoutGridValue(rowCount: Int(tabDesign.horizontalKeyCount), columnCount: Int(tabDesign.verticalKeyCount))
        CustardFlickKeysView(models: models, tabDesign: tabDesign, layout: layout, blur: true) {(view: FlickKeyView<Extension>, _, _) in
            view
        }
    }
}
