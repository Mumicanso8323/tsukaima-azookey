import SwiftUI

// swiftlint:disable:next type_name
struct iOS16TerminationNewsView: View {
    internal init(_ readThisMessage: Binding<Bool>) {
        self._readThisMessage = readThisMessage
    }
    @Binding private var readThisMessage: Bool

    var body: some View {
        TipsContentView("iOS 16のサポートを終了します") {
            TipsContentParagraph {
                Text("バージョン2.5(公開時期未定)以降のazooKeyではiOS 16のサポートを終了する予定です。")
            }
            TipsContentParagraph {
                Text("iOS 17以降では引き続き最新バージョンのazooKeyをご利用いただけます。")
            }
            TipsContentParagraph {
                Text("ぜひiOSをアップデートしてazooKeyをご利用ください。")
            }
        }
        .onAppear {
            self.readThisMessage = true
        }
    }
}
