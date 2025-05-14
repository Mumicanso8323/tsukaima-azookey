import SwiftUI

public struct EditCancelButton: View {
    public init() {}
    
    @State private var showCancellationAlert: Bool = false
    @Environment(\.dismiss) private var dismiss
    public var body: some View {
        Button("キャンセル", role: .cancel) {
            self.showCancellationAlert = true
        }
        .alert("編集を中止します。変更はすべて失われます。", isPresented: $showCancellationAlert) {
            Button("編集を中止する", role: .destructive) {
                self.dismiss()
            }
        }
    }
}
