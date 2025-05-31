import SwiftUI

struct TermsOfServiceUpdateNews: View {
    @AppStorage("read_terms_of_use_update_2025_05_31") private var readTermsOfUseUpdate_2025_05_31 = false

    var body: some View {
        TipsContentView("利用規約を更新しました") {
            TipsContentParagraph {
                Text("必ずご確認ください。")
            }
            FallbackLink("利用規約", destination: URL(string: "https://azookey.netlify.app/TermsOfService")!)
        }
        .onAppear {
            self.readTermsOfUseUpdate_2025_05_31 = true
        }
    }
}
