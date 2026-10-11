import AzooKeyUtils
import SwiftUI
import UIKit

/// 薙刀式の練習画面。練習文を 1 つずつ出し、次に打つキーを配列図で光らせる。
/// 入力欄は薙刀式オンの専用インスタンス(グローバル設定には触らない)。
struct NaginataPracticeView: View {
    @StateObject private var session = HardwareIMESession()
    @State private var sentenceIndex = 0
    @State private var progress = NaginataPracticeProgress(target: NaginataPractice.sentences[0])
    @State private var text = ""

    private var typed: String { text + session.composingText }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\\(sentenceIndex + 1) / \\(NaginataPractice.sentences.count)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("naginata.practice.counter")

                targetText
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .accessibilityIdentifier("naginata.practice.target")

                if let next = progress.nextToken {
                    Text("次: \\(next.text)")
                        .font(.title2)
                        .accessibilityIdentifier("naginata.practice.next")
                } else {
                    Text("できました")
                        .font(.title2).foregroundStyle(.green)
                        .accessibilityIdentifier("naginata.practice.done")
                }

                HardwareIMETextEditor(text: $text, placeholder: "ここに打つ", minLines: 2, maxLines: 4,
                                      font: .preferredFont(forTextStyle: .title2),
                                      accessibilityID: "naginata.practice.editor", session: session)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button("やり直し") { restart() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("naginata.practice.retry")
                    Button("次へ") { goNext() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("naginata.practice.nextSentence")
                }
                .font(.title3)

                NaginataLayoutFigure(base: roles.base, modifier: roles.modifier)
            }
            .padding()
        }
        .navigationTitle("薙刀式の練習")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.core.naginata = true }
        .onChange(of: text) { _, _ in progress.update(typed: typed) }
        .onChange(of: session.composingText) { _, _ in progress.update(typed: typed) }
    }

    private var roles: (base: Set<Character>, modifier: Set<Character>) {
        guard let next = progress.nextToken else { return ([], []) }
        return NaginataPractice.roles(for: next.keys)
    }

    private var targetText: Text {
        let chars = Array(progress.target)
        let done = String(chars.prefix(progress.matched))
        let rest = String(chars.dropFirst(progress.matched))
        return Text(done).foregroundColor(.green) + Text(rest).foregroundColor(.primary)
    }

    private func clearInput() {
        session.textView?.apply(session.core.cancelAll())
        text = ""
    }

    private func restart() {
        clearInput()
        progress = NaginataPracticeProgress(target: NaginataPractice.sentences[sentenceIndex])
    }

    private func goNext() {
        clearInput()
        sentenceIndex = (sentenceIndex + 1) % NaginataPractice.sentences.count
        progress = NaginataPracticeProgress(target: NaginataPractice.sentences[sentenceIndex])
    }
}
