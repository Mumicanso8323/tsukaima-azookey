import SwiftUI

/// UI テスト専用の入力欄の試験台(起動引数 `--input-lab`)。本番では出ない。
/// 0.25 秒ごとに画面全体を描き直しながら(録音中・ポーリング中の再描画と同じ状況)、各種の入力欄に
/// 日本語を変換しながら打てるかを確かめる(MainAppUITests/TsukaimaJapaneseInputUITests)。
struct TsukaimaInputLab: View {
    static let isActive = ProcessInfo.processInfo.arguments.contains("--input-lab")

    @State private var tick = 0
    @State private var composer = ""
    @State private var editor = ""
    @State private var swiftUIVertical = ""
    @State private var swiftUISingle = ""

    var body: some View {
        List {
            Text("再描画 \(tick)")
                .font(.caption.monospacedDigit())
                .accessibilityIdentifier("lab.tick")
            Section("使い魔の入力欄(アンケート・Claude タブ・チャット)") {
                TsukaimaComposerField(placeholder: "一行から伸びる欄", text: $composer, maxLines: 6, accessibilityID: "lab.composer")
                Text("値: \(composer)").font(.caption).accessibilityIdentifier("lab.composer.binding")
            }
            Section("使い魔の複数行(メモ・下書き)") {
                TsukaimaTextEditor(text: $editor, minLines: 3, maxLines: 8, accessibilityID: "lab.editor")
                Text("値: \(editor)").font(.caption).accessibilityIdentifier("lab.editor.binding")
            }
            Section("比較: SwiftUI の TextField") {
                TextField("縦に伸びる TextField", text: $swiftUIVertical, axis: .vertical)
                    .accessibilityIdentifier("lab.swiftuiVertical")
                TextField("一行の TextField", text: $swiftUISingle)
                    .accessibilityIdentifier("lab.swiftuiSingle")
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                tick += 1
            }
        }
    }
}
