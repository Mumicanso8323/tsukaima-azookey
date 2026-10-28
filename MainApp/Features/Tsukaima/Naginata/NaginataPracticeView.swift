import AzooKeyUtils
import SwiftUI
import UIKit

/// 薙刀式の練習画面。練習文を 1 つずつ出し、次に打つキーを配列図で光らせる。
/// 入力欄は薙刀式オンの専用インスタンス(グローバル設定には触らない)。
///
/// 物理キーボードだけで続けられるようにする(画面に触らない):
///   - 開くと入力欄にフォーカスが入る。物理キーボード接続中は外れても FocusGuard が戻す(pinsFocus)。
///   - お題を打ち終えたら、自動で次のお題へ進む(結果は「前のお題」として上に残す)。
///   - Esc: やり直し / Tab: 飛ばして次へ / Enter: 改行は入れない(編集中なら確定だけ)。
///   - フォーカスが外れているときは「Enter で始める」ボタンが Enter で押せる。
/// iPhone の縦画面で見る前提で、配列図は左手を上・右手を下に分けて大きく出す。
struct NaginataPracticeView: View {
    @StateObject private var session = HardwareIMESession()
    @State private var sentenceIndex = 0
    @State private var progress = NaginataPracticeProgress(target: NaginataPractice.sentences[0])
    @State private var text = ""
    @State private var logSession = UUID().uuidString
    @State private var editorFocused = false
    /// 直前に打ち終えたお題の結果(自動で次へ進んだあとも残す)
    @State private var lastResult: LastResult?

    private struct LastResult: Equatable {
        let target: String
        let charsPerMinute: Double?
        let errors: Int
    }

    private var typed: String { text + session.composingText }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(sentenceIndex + 1) / \(NaginataPractice.sentences.count)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("naginata.practice.counter")
                    Spacer()
                    if let lastResult {
                        resultLine(lastResult)
                    }
                }

                targetText
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("naginata.practice.target")

                HStack {
                    if let next = progress.nextToken {
                        Text("次: \(next.text)")
                            .font(.title2.weight(.semibold))
                            .accessibilityIdentifier("naginata.practice.next")
                    }
                    Spacer()
                    controls
                }

                HardwareIMETextEditor(text: $text, placeholder: "ここに打つ", focused: $editorFocused, pinsFocus: true,
                                      minLines: 1, maxLines: 2,
                                      font: .preferredFont(forTextStyle: .title2),
                                      accessibilityID: "naginata.practice.editor", session: session)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(editorFocused ? Color.accentColor : Color.clear, lineWidth: 2)
                    )

                Text("打ち終えると自動で次へ ・ Esc やり直し ・ Tab 飛ばす")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if NaginataMock.isActive {
                    // UI テスト専用: 入力欄にフォーカスがあるか
                    Text(editorFocused ? "focused" : "unfocused")
                        .font(.caption2)
                        .accessibilityIdentifier("naginata.practice.focus")
                }
                NaginataMockKeysBar(session: session, nextKeys: progress.nextToken?.keys, commandKeys: true)

                NaginataLayoutFigure(base: roles.base, modifier: roles.modifier, split: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle("薙刀式の練習")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            session.core.naginata = true
            attachHandlers()
            editorFocused = true
        }
        .task {
            await Task.yield()
            attachHandlers()
            // 最初の要求が画面に載る前で消費されなかったときの保険(触らずに打ち始められるように)
            try? await Task.sleep(for: .milliseconds(300))
            if let view = session.textView, !view.isFirstResponder {
                _ = view.becomeFirstResponder()
            }
        }
        .onChange(of: text) { _, _ in updateProgress() }
        .onChange(of: session.composingText) { _, _ in updateProgress() }
    }

    /// フォーカスがあるときはボタンだけ(キーは入力欄が受ける)。外れているときは Enter・Esc でも押せる。
    @ViewBuilder
    private var controls: some View {
        if editorFocused {
            HStack(spacing: 8) {
                Button("やり直し") { restart() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("naginata.practice.retry")
                Button("次へ") { goNext() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("naginata.practice.nextSentence")
            }
        } else {
            HStack(spacing: 8) {
                Button("やり直し") { restart() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("naginata.practice.retry")
                Button("Enter で始める") { editorFocused = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("naginata.practice.start")
            }
        }
    }

    private func resultLine(_ result: LastResult) -> some View {
        HStack(spacing: 6) {
            Text("できました")
                .foregroundStyle(.green)
                .accessibilityIdentifier("naginata.practice.done")
            if let cpm = result.charsPerMinute {
                Text("\(Int(cpm.rounded())) 字/分 ・ 間違い \(result.errors) 回")
                    .accessibilityIdentifier("naginata.practice.result")
            }
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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

    private func attachHandlers() {
        let id = logSession
        session.textView?.naginataKeyLogger = { key, down, t in
            NaginataKeyLog.append(NaginataKeyLog.line(session: id, key: key, down: down, t: t))
        }
        session.textView?.commandKeyHandler = { key in handleCommandKey(key) }
    }

    /// 物理キーボードの Enter・Esc・Tab(入力欄が受けたもの)。true なら IME にもテキストにも渡さない。
    private func handleCommandKey(_ key: HardwareIMEKey) -> Bool {
        switch key {
        case .escape:
            restart()
            return true
        case .tab:
            goNext()
            return true
        case .enter:
            // 編集中は IME の確定に任せる(確定しても打った文字は変わらない)
            if session.core.isComposing { return false }
            if progress.isComplete { goNext() }
            // 改行は入れない(入れると間違いに数えてしまう)
            return true
        default:
            return false
        }
    }

    private func updateProgress() {
        progress.update(typed: typed, at: ProcessInfo.processInfo.systemUptime)
        guard progress.isComplete else { return }
        let index = sentenceIndex
        lastResult = LastResult(target: progress.target, charsPerMinute: progress.charsPerMinute, errors: progress.errors)
        // 入力欄の更新の途中で書き換えないよう、一拍おいてから次へ(同じお題で 2 回呼ばれても 1 回だけ進む)
        Task { @MainActor in
            await Task.yield()
            guard sentenceIndex == index, progress.isComplete else { return }
            goNext()
        }
    }

    private func clearInput() {
        session.textView?.apply(session.core.cancelAll())
        text = ""
    }

    private func restart() {
        clearInput()
        progress = NaginataPracticeProgress(target: NaginataPractice.sentences[sentenceIndex])
        editorFocused = true
    }

    private func goNext() {
        clearInput()
        sentenceIndex = (sentenceIndex + 1) % NaginataPractice.sentences.count
        progress = NaginataPracticeProgress(target: NaginataPractice.sentences[sentenceIndex])
        editorFocused = true
    }
}
