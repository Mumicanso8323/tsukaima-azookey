import AzooKeyUtils
import GameController
import SwiftUI
import UIKit

/// 1 つの入力欄ぶんの IME 状態(候補・かな/英数)。候補バーと UITextView の橋渡し。
@MainActor
final class HardwareIMESession: ObservableObject {
    let core: HardwareIMECore
    @Published private(set) var candidates: [String] = []
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var isKana = true
    @Published private(set) var isComposing = false
    @Published var hardwareAttached = false
    weak var textView: HardwareIMETextView? {
        didSet { box.view = textView }
    }
    private let box: WeakTextViewBox
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    private final class WeakTextViewBox {
        weak var view: HardwareIMETextView?
    }

    init() {
        let box = WeakTextViewBox()
        self.box = box
        core = HardwareIMECore(provider: HardwareIMEConverter.shared, leftContext: { box.view?.leftContextText() ?? "" })
        hardwareAttached = HardwareIMETextView.hardwareKeyboardAttached
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.hardwareAttached = HardwareIMETextView.hardwareKeyboardAttached }
            })
        }
        // 背面に回るときは編集中のものを確定して学習を書き出す
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.textView?.apply(self.core.commitAll())
                HardwareIMEConverter.shared.flushLearning()
                self.refresh()
            }
        })
    }

    deinit {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
    }

    func attach(_ textView: HardwareIMETextView) {
        self.textView = textView
        textView.onIMEStateChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        candidates = core.candidates.map(\.text)
        selectedIndex = core.selectedIndex
        isKana = core.mode == .kana
        isComposing = core.isComposing
    }

    func select(_ index: Int) {
        textView?.apply(core.commitCandidate(at: index))
        refresh()
    }

    func toggleMode() {
        let result = core.handle(.toggleMode)
        textView?.apply(result.effects)
        refresh()
    }
}

/// UITextView(HardwareIMETextView)を SwiftUI に出す。高さは内容に合わせて minLines〜maxLines の間で伸びる。
/// バインディングの text には編集中(marked)の文字列を含めない(送信ボタンが未確定のかなを送らないため)。
///
/// 再描画(打鍵・イベント到着・ポーリング・前面復帰…)は何度でも来るので、updateUIView は「状態を合わせる」
/// のではなく「外から来た変更だけを渡す」:
///   - text: バインディングが外から変わった時(送信で空にする・定型文を入れる)だけ UITextView に書く。
///     打鍵で変わった分は UITextView が正本なので書き戻さない(書くとカーソルが末尾へ飛び、確定前の文字が消える)。
///   - focused: 呼び出し側の要求が変わった時(false→true / true→false)だけ反映する。毎回「要求と違えば直す」
///     をすると、要求側が追いついていない再描画のたびにフォーカスを外してしまう(2026-10-02 の不具合の原因)。
struct HardwareIMETextEditor: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focused: Binding<Bool>?
    var minLines: Int = 1
    var maxLines: Int = 6
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var backgroundColor: UIColor = .clear
    var textInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    /// UI テストで入力欄を見つけるための識別子
    var accessibilityID: String?
    @ObservedObject var session: HardwareIMESession

    func makeUIView(context: Context) -> HardwareIMETextView {
        let view = HardwareIMETextView(ime: session.core)
        view.delegate = context.coordinator
        view.font = font
        view.backgroundColor = backgroundColor
        view.textContainerInset = textInset
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.text = text
        view.accessibilityIdentifier = accessibilityID
        let label = UILabel()
        label.font = font
        label.textColor = .placeholderText
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: textInset.left),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -textInset.right),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: textInset.top),
        ])
        context.coordinator.placeholderLabel = label
        session.attach(view)
        return view
    }

    func updateUIView(_ uiView: HardwareIMETextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // text: 外から変わった時だけ書く(打鍵による変化は coordinator.lastText に記録済みなので一致する)
        if text != coordinator.lastText {
            coordinator.lastText = text
            if text != Coordinator.committedText(of: uiView) {
                if uiView.markedTextRange != nil { uiView.unmarkText() }
                uiView.text = text
                coordinator.updatePlaceholder(uiView)
                uiView.invalidateIntrinsicContentSize()
            }
        }
        coordinator.placeholderLabel?.text = placeholder
        coordinator.updatePlaceholder(uiView)
        // focused: 要求が変わった時だけ反映する(エッジ)
        if let focused {
            let wants = focused.wrappedValue
            if wants != coordinator.lastRequestedFocus {
                if wants {
                    // まだ画面に載っていなければ要求を消費せず、次の更新でもう一度試す
                    if uiView.window != nil {
                        coordinator.lastRequestedFocus = true
                        if !uiView.isFirstResponder {
                            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
                        }
                    }
                } else {
                    coordinator.lastRequestedFocus = false
                    if uiView.isFirstResponder {
                        DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
                    }
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HardwareIMETextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.window?.bounds.width ?? 320
        let lineHeight = font.lineHeight
        let minH = lineHeight * CGFloat(max(minLines, 1)) + textInset.top + textInset.bottom
        let maxH = lineHeight * CGFloat(max(maxLines, minLines)) + textInset.top + textInset.bottom
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(max(fitting.height, minH), maxH)
        let needsScroll = fitting.height > maxH + 0.5
        if uiView.isScrollEnabled != needsScroll {
            uiView.isScrollEnabled = needsScroll
        }
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HardwareIMETextEditor
        var placeholderLabel: UILabel?
        /// UITextView と最後に揃えた(確定済みの)文字列。これと違う値がバインディングに来たら「外からの変更」。
        var lastText: String
        /// 最後に反映した(または UITextView 側で起きた)フォーカスの状態。要求の変化を見分けるのに使う。
        var lastRequestedFocus = false

        init(parent: HardwareIMETextEditor) {
            self.parent = parent
            self.lastText = parent.text
        }

        /// UITextView 側の変化をバインディングへ(打鍵・削除・未確定文字の確定・IME の候補確定)
        func syncFromView(_ textView: UITextView) {
            let committed = Self.committedText(of: textView)
            guard committed != lastText else { return }
            lastText = committed
            if parent.text != committed {
                parent.text = committed
            }
        }

        func updatePlaceholder(_ textView: UITextView) {
            placeholderLabel?.isHidden = !(textView.text ?? "").isEmpty || textView.markedTextRange != nil
        }

        /// marked(編集中)の部分を除いたテキスト
        static func committedText(of textView: UITextView) -> String {
            let full = textView.text ?? ""
            guard let marked = textView.markedTextRange else {
                return full
            }
            let start = textView.offset(from: textView.beginningOfDocument, to: marked.start)
            let end = textView.offset(from: textView.beginningOfDocument, to: marked.end)
            let ns = full as NSString
            guard start >= 0, end <= ns.length, start <= end else {
                return full
            }
            return ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: "")
        }

        func textViewDidChange(_ textView: UITextView) {
            syncFromView(textView)
            updatePlaceholder(textView)
            textView.invalidateIntrinsicContentSize()
        }

        /// キーボード拡張が未確定の文字を確定(unmarkText)したときは textViewDidChange が来ないことがあるので、
        /// 選択位置の変化でも拾う(拾い損ねると送信ボタンが確定分を送らない)。
        func textViewDidChangeSelection(_ textView: UITextView) {
            syncFromView(textView)
            updatePlaceholder(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            lastRequestedFocus = true
            if parent.focused?.wrappedValue == false {
                parent.focused?.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            lastRequestedFocus = false
            if parent.focused?.wrappedValue == true {
                parent.focused?.wrappedValue = false
            }
        }
    }
}

/// 候補バー: 編集中だけ出る。タップで確定。右端にかな/英数の切り替え。
struct HardwareIMECandidateBar: View {
    @ObservedObject var session: HardwareIMESession

    var body: some View {
        if session.isComposing || session.hardwareAttached {
            HStack(spacing: 6) {
                if session.isComposing, !session.candidates.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(session.candidates.enumerated()), id: \.offset) { index, text in
                                    Button {
                                        session.select(index)
                                    } label: {
                                        HStack(spacing: 3) {
                                            if index < 9 {
                                                Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Text(text).lineLimit(1)
                                        }
                                        .font(.subheadline)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            session.selectedIndex == index ? Color.accentColor.opacity(0.25) : Color(.tertiarySystemFill),
                                            in: Capsule()
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .id(index)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        .onChange(of: session.selectedIndex) { _, index in
                            if let index {
                                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
                            }
                        }
                    }
                } else if session.isComposing {
                    Text("候補なし").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Text("Space 変換 · Enter 確定 · Esc 戻す · Caps Lock かな/英数")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                }
                Button {
                    session.toggleMode()
                } label: {
                    Text(session.isKana ? "あ" : "A")
                        .font(.subheadline.bold())
                        .frame(width: 30, height: 26)
                        .background(session.isKana ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isKana ? "かな入力(英数に切り替え)" : "英数入力(かなに切り替え)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

/// チャット・Claude タブなどの入力欄。設定がオンなら IME つきの UITextView、オフなら普通の TextField。
/// 見た目(角丸の背景など)は呼び出し側で付ける。
@MainActor
struct TsukaimaComposerField: View {
    let placeholder: String
    @Binding var text: String
    var focused: Binding<Bool>?
    var maxLines: Int = 6
    var textInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    var accessibilityID: String?
    @AppStorage(HardwareIMESettings.enabledKey) private var imeEnabled = true
    @StateObject private var session = HardwareIMESession()

    var body: some View {
        if imeEnabled, HardwareIMEConverter.shared.isAvailable {
            VStack(spacing: 2) {
                HardwareIMECandidateBar(session: session)
                HardwareIMETextEditor(text: $text, placeholder: placeholder, focused: focused, maxLines: maxLines, textInset: textInset,
                                      accessibilityID: accessibilityID, session: session)
            }
        } else {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...maxLines)
                .focused($fallbackFocus)
                .accessibilityIdentifier(accessibilityID ?? "")
                .padding(.horizontal, textInset.left)
                .padding(.vertical, textInset.top)
                .onChange(of: focused?.wrappedValue ?? false) { _, wants in
                    if fallbackFocus != wants { fallbackFocus = wants }
                }
                .onChange(of: fallbackFocus) { _, now in
                    if let focused, focused.wrappedValue != now { focused.wrappedValue = now }
                }
        }
    }

    @FocusState private var fallbackFocus: Bool
}

/// メモ・下書きなど複数行の入力欄(TextEditor の置き換え)。設定オフなら TextEditor。
@MainActor
struct TsukaimaTextEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var minLines: Int = 5
    var maxLines: Int = 40
    @AppStorage(HardwareIMESettings.enabledKey) private var imeEnabled = true
    @StateObject private var session = HardwareIMESession()

    var body: some View {
        if imeEnabled, HardwareIMEConverter.shared.isAvailable {
            VStack(spacing: 2) {
                HardwareIMECandidateBar(session: session)
                HardwareIMETextEditor(text: $text, placeholder: placeholder, minLines: minLines, maxLines: maxLines, textInset: UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6), session: session)
            }
        } else {
            TextEditor(text: $text)
        }
    }
}

/// 設定タブのセクション
struct HardwareIMESettingsSection: View {
    @AppStorage(HardwareIMESettings.enabledKey) private var imeEnabled = true

    var body: some View {
        Section {
            Toggle("Bluetooth キーボードで日本語変換", isOn: $imeEnabled)
            if !HardwareIMEConverter.shared.isAvailable {
                Text("変換辞書が見つかりません(Keyboard.appex の辞書バンドルを読めませんでした)。このビルドでは変換できません。")
                    .font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("物理キーボード")
        } footer: {
            Text("""
            使い魔タブ・Claude タブ・メモの入力欄で、繋いだキーボードのローマ字入力を使い魔キーと同じエンジンで変換します(iOS の制限で、キーボード拡張には物理キーの入力が届かないため本体側で変換します)。
            Space: 変換・次の候補 / Shift+Space・↑: 前の候補 / Enter: 確定 / Esc: 戻す・取り消し / F7: カタカナ / F10: 英数。
            かな⇔英数は Caps Lock・かな/英数キー・Ctrl+Space、または候補バー右端のボタン。
            iOS 側の物理キーボードの言語は「英語(ABC)」にしてください(日本語 - ローマ字だと OS の変換と二重になります)。
            hub のユーザ辞書・定型文・TRPG 語彙は使い魔キーと共通。学習は本体アプリ内で別に育ちます。
            """)
        }
    }
}
