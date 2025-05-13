import SwiftUI

public struct HelpAlertButton: View {
    public init(_ explanation: LocalizedStringKey) {
        self.explanation = explanation
    }
    var explanation: LocalizedStringKey

    @State private var showAlert = false
    public var body: some View {
        Button {
            showAlert = true
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .alert(explanation, isPresented: $showAlert) {
            Button("OK") {
                self.showAlert = false
            }
        }
    }
}
