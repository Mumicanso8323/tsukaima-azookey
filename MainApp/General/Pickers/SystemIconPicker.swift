//
//  SystemIconPicker.swift
//  azooKey
//
//  Created by miwa on 2024/10/07.
//  Copyright © 2024 DevEn3. All rights reserved.
//

import SwiftUI

struct SystemIconPicker: View {
    init(
        icon: Binding<String>,
        recommendation: [String] = [
            "doc.on.doc",
            "doc.on.doc.fill",
            "doc.on.clipboard",
            "doc.on.clipboard.fill",
            "scissors",
            "delete.left",
            "delete.left.fill",
            "delete.right",
            "delete.right.fill",
            "heart",
            "clear",
            "clear.fill",
            "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right",
            "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right.fill",
            "xmark",
            "shift",
            "shift.fill",
            "capslock",
            "capslock.fill",
            "globe",
            "keyboard.chevron.compact.down",
            "keyboard.chevron.compact.down.fill",
            "space",
            "return",
            "command",
        ]
    ) {
        self._icon = icon
        self.recommendation = recommendation
    }

    private var recommendation: [String]

    @Binding var icon: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(), count: 5)) { // カラム数の指定
            ForEach(recommendation.indices, id: \.self) { index in
                Button {
                    self.icon = self.recommendation[index]
                } label: {
                    if self.icon == self.recommendation[index] {
                        Image(systemName: self.recommendation[index])
                            .frame(width: 45, height: 45)
                            .foregroundStyle(.white)
                            .background(.tint)
                            .cornerRadius(10)
                    } else {
                        Image(systemName: self.recommendation[index])
                            .frame(width: 45, height: 45)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        HStack {
            TextField("ID", text: $icon, prompt: Text("SF SymbolsのIDを指定"))
                .textFieldStyle(.roundedBorder)
                .monospaced()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
            Image(systemName: self.icon)
                .frame(width: 45, height: 45)
                .foregroundStyle(.white)
                .background(.tint)
                .cornerRadius(10)
        }
        .padding(.horizontal)
    }
}

@available(iOS 17, *)
#Preview {
    @Previewable @State var icon = "star"
    return SystemIconPicker(icon: $icon)
}
