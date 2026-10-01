import SwiftUI

/// `{"type":"choice"}`(docs/converse-protocol.md 2章): Claude Code が画面に出している AskUserQuestion の選択肢。
/// `questions` が null なら消去(同じ tool_use_id)。
struct ClaudeChoice: Equatable {
    struct Option: Equatable, Identifiable {
        var id: Int { index }
        let index: Int
        let label: String
        let description: String
    }

    struct Question: Equatable, Identifiable {
        var id: Int { index }
        let index: Int
        let question: String
        let header: String
        let multiSelect: Bool
        let options: [Option]
    }

    let toolUseID: String
    let session: String?
    let questions: [Question]

    /// 消去(questions: null)は .cleared(id)、それ以外は .show(choice)。形が読めなければ nil
    enum Parsed: Equatable { case show(ClaudeChoice), cleared(String) }

    static func parse(_ obj: [String: Any]) -> Parsed? {
        guard let id = obj["tool_use_id"] as? String, !id.isEmpty else { return nil }
        guard let qs = obj["questions"] as? [[String: Any]] else { return .cleared(id) }
        let questions = qs.enumerated().map { i, q -> Question in
            let opts = (q["options"] as? [[String: Any]] ?? []).enumerated().map { j, o in
                Option(index: (o["index"] as? NSNumber)?.intValue ?? j,
                       label: o["label"] as? String ?? "", description: o["description"] as? String ?? "")
            }
            return Question(index: (q["index"] as? NSNumber)?.intValue ?? i,
                            question: q["question"] as? String ?? "", header: q["header"] as? String ?? "",
                            multiSelect: (q["multi_select"] as? Bool) ?? false, options: opts)
        }
        guard !questions.isEmpty else { return .cleared(id) }
        return .show(ClaudeChoice(toolUseID: id, session: obj["session"] as? String, questions: questions))
    }
}

/// 選択肢の操作の状態機械(純ロジック)。入力欄にカーソルを置いたまま、
///   欄が空: 数字 1〜9 で選んで即送信(複数選択はトグル)、↑↓ で移動、Enter で決定、Space でトグル(複数選択)
///   欄に文字: Enter は「その他(自由入力)」としてその文字を回答にする
///   ⌘+数字: 欄の中身に関係なく番号で選ぶ
/// 質問が複数あれば順に答え、全部そろったら `.submit` で `{"type":"choice_answer"}` の answers を返す。
struct ClaudeChoiceSelection: Equatable {
    struct Answer: Equatable {
        let questionIndex: Int
        let selected: [Int]
        let otherText: String?

        var json: [String: Any] {
            ["question_index": questionIndex, "selected": selected, "other_text": otherText ?? NSNull()]
        }
    }

    enum Outcome: Equatable {
        /// 何も起きなかった(Optional.none と紛れないよう none とは名付けない)
        case ignored
        /// 画面の表示が変わっただけ(移動・トグル・次の質問へ)
        case changed
        /// 全質問の回答がそろった
        case submit([Answer])
    }

    let choice: ClaudeChoice
    private(set) var questionIndex = 0
    private(set) var highlighted = 0
    private(set) var checked: Set<Int> = []
    private(set) var answers: [Answer] = []

    init(choice: ClaudeChoice) {
        self.choice = choice
    }

    var question: ClaudeChoice.Question { choice.questions[min(questionIndex, choice.questions.count - 1)] }
    var isLastQuestion: Bool { questionIndex >= choice.questions.count - 1 }

    /// 素のキー(欄が空のとき。Esc は常に来る)。消費したら Outcome、関係ないキーなら nil(欄に流す)
    mutating func handle(_ key: ComposerPlainKey, composerText: String) -> Outcome? {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case .enter:
            if !text.isEmpty { return commit(selected: [], other: text) }
            if question.multiSelect {
                guard !checked.isEmpty else { return .ignored }
                return commit(selected: checked.sorted(), other: nil)
            }
            return commit(selected: [highlighted], other: nil)
        case .escape:
            return nil  // 選択肢は閉じない(入力欄を閉じる合図として親に流す)
        default:
            break
        }
        guard text.isEmpty else { return nil }
        switch key {
        case .digit(let n):
            return pick(number: n)
        case .up:
            highlighted = max(highlighted - 1, 0)
            return .changed
        case .down:
            highlighted = min(highlighted + 1, question.options.count - 1)
            return .changed
        case .space:
            guard question.multiSelect else { return nil }
            toggle(highlighted)
            return .changed
        case .enter, .escape:
            return nil
        }
    }

    /// 番号で選ぶ(1 始まり)。単一選択は即決定、複数選択はトグル。⌘+数字とボタンのタップもここ。
    mutating func pick(number n: Int) -> Outcome {
        let i = n - 1
        guard question.options.indices.contains(i) else { return .ignored }
        if question.multiSelect {
            toggle(i)
            highlighted = i
            return .changed
        }
        return commit(selected: [i], other: nil)
    }

    /// 複数選択の「決定」ボタン
    mutating func confirmMulti() -> Outcome {
        guard question.multiSelect, !checked.isEmpty else { return .ignored }
        return commit(selected: checked.sorted(), other: nil)
    }

    private mutating func toggle(_ i: Int) {
        if checked.contains(i) { checked.remove(i) } else { checked.insert(i) }
    }

    private mutating func commit(selected: [Int], other: String?) -> Outcome {
        answers.append(Answer(questionIndex: question.index, selected: selected, otherText: other))
        if isLastQuestion {
            return .submit(answers)
        }
        questionIndex += 1
        highlighted = 0
        checked = []
        return .changed
    }
}

/// 入力欄の上の小さなボタン列。ボタンはフォーカスを奪わない(SwiftUI の Button は first responder にならない)。
/// 出る/消えるときに入力欄の位置が跳ねないよう、外側(ClaudeComposerView)が高さを予約する。
struct ClaudeChoiceBar: View {
    let selection: ClaudeChoiceSelection
    let onPick: (Int) -> Void      // 1 始まりの番号
    let onConfirm: () -> Void       // 複数選択の決定

    static let height: CGFloat = 46

    var body: some View {
        let q = selection.question
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle").font(.caption2).foregroundStyle(.purple)
                Text(q.header.isEmpty ? q.question : "\(q.header): \(q.question)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if selection.choice.questions.count > 1 {
                    Text("\(selection.questionIndex + 1)/\(selection.choice.questions.count)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(q.options) { o in
                        let on = q.multiSelect ? selection.checked.contains(o.index) : selection.highlighted == o.index
                        Button {
                            onPick(o.index + 1)
                        } label: {
                            HStack(spacing: 3) {
                                Text("\(o.index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Text(o.label).font(.caption).lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(on ? Color.accentColor.opacity(0.25) : Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("claude.choice.\(o.index + 1)")
                    }
                    if q.multiSelect {
                        Button("決定", action: onConfirm)
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .disabled(selection.checked.isEmpty)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .accessibilityIdentifier("claude.choiceBar")
    }
}
