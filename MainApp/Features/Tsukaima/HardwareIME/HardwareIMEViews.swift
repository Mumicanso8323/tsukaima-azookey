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
struct HardwareIMETextEditor: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focused: Binding<Bool>?
    var minLines: Int = 1
    var maxLines: Int = 6
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var backgroundColor: UIColor = .clear
    var textInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    /// true なら「本人が明示的に閉じるまでカーソルを離さない」(ComposerFocusIntent)。Claude タブで使う。
    var keepsFocus = false
    var accessibilityID: String?
    var onSubmit: (@MainActor () -> Void)?
    var onPlainKey: (@MainActor (ComposerPlainKey) -> Bool)?
    var onBinding: (@MainActor (ComposerKeyBinding) -> Bool)?
    @ObservedObject var session: HardwareIMESession

    func makeUIView(context: Context) -> HardwareIMETextView {
        let view = HardwareIMETextView(ime: session.core)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = accessibilityID
        context.coordinator.wire(view)
        view.font = font
        view.backgroundColor = backgroundColor
        view.textContainerInset = textInset
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.text = text
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
        context.coordinator.parent = self
        context.coordinator.wire(uiView)
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
            context.coordinator.updatePlaceholder(uiView)
            uiView.invalidateIntrinsicContentSize()
        }
        context.coordinator.placeholderLabel?.text = placeholder
        context.coordinator.updatePlaceholder(uiView)
        if let focused {
            // 親のバインディングは「意図」。true なら付け直し、false なら(親が明示的に閉じたので)外す。
            // 再描画のたびにここを通るが、first responder の状態と一致していれば何もしない(= 再描画は焦点に触らない)。
            let wants = focused.wrappedValue
            if wants, !uiView.isFirstResponder, uiView.window != nil {
                _ = context.coordinator.intent.apply(.parentRequestedFocus)
                context.coordinator.restoreFocus(uiView)
            } else if !wants, uiView.isFirstResponder {
                _ = context.coordinator.intent.apply(.userDismissed)
                Task { @MainActor in _ = uiView.resignFirstResponder() }
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
        /// 「カーソルを置いておきたい」意図(keepsFocus のときだけ使う)
        var intent = ComposerFocusIntent()
        private var restoreAttempts = 0

        init(parent: HardwareIMETextEditor) {
            self.parent = parent
        }

        /// 毎回の update で閉包を差し替える(親の @State を捕まえた古い閉包を残さない)
        func wire(_ view: HardwareIMETextView) {
            view.onSubmit = parent.onSubmit.map { submit in { @MainActor [weak self, weak view] in
                submit()
                if let view { self?.afterSend(view) }
            } }
            view.onPlainKey = parent.onPlainKey
            view.onBinding = parent.onBinding
        }

        /// 送信後: 意図があればカーソルを付け直す(欄が空になっても・一覧が伸びても外れない)
        func afterSend(_ view: HardwareIMETextView) {
            guard parent.keepsFocus, intent.apply(.sent) == .restore else { return }
            restoreFocus(view)
        }

        /// 次のランループで becomeFirstResponder し直す。メニュー・シートの表示中は失敗するので短く数回だけ粘る
        /// (閉じた後は updateUIView 経由でも付け直すので、ここで無限に粘らない)
        func restoreFocus(_ view: HardwareIMETextView, attempt: Int = 0) {
            Task { @MainActor [weak self, weak view] in
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
                guard let self, let view else { return }
                guard self.intent.wantsFocus || self.parent.focused?.wrappedValue == true else { return }
                guard !view.isFirstResponder else { return }
                if view.window != nil, view.becomeFirstResponder() { return }
                if attempt < 8 { self.restoreFocus(view, attempt: attempt + 1) }
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
            let committed = Self.committedText(of: textView)
            if parent.text != committed {
                parent.text = committed
            }
            updatePlaceholder(textView)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            _ = intent.apply(.userBeganEditing)
            if parent.focused?.wrappedValue == false {
                parent.focused?.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.keepsFocus {
                // 本人が閉じたのでなければ(メニュー・シート・再描画・IME の付け替え…)付け直す。親のバインディングは触らない
                if intent.apply(.editingEnded) == .restore, let view = textView as? HardwareIMETextView {
                    restoreFocus(view)
                }
                return
            }
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
    /// true: 本人が明示的に閉じるまでカーソルを離さない(Claude タブ)。IME オフの TextField でも同じ扱い。
    var keepsFocus = false
    var accessibilityID: String?
    /// 物理キーボードの素の Enter で呼ぶ(nil なら改行)。Shift+Enter は常に改行
    var onSubmit: (@MainActor () -> Void)?
    var onPlainKey: (@MainActor (ComposerPlainKey) -> Bool)?
    var onBinding: (@MainActor (ComposerKeyBinding) -> Bool)?
    /// 親からカーソル位置に文字を差し込む(音声入力)ための取っ手
    var controller: ComposerFieldController?
    @AppStorage(HardwareIMESettings.enabledKey) private var imeEnabled = true
    @StateObject private var session = HardwareIMESession()

    var body: some View {
        if imeEnabled, HardwareIMEConverter.shared.isAvailable {
            VStack(spacing: 2) {
                HardwareIMECandidateBar(session: session)
                HardwareIMETextEditor(text: $text, placeholder: placeholder, focused: focused, maxLines: maxLines, textInset: textInset,
                                      keepsFocus: keepsFocus, accessibilityID: accessibilityID,
                                      onSubmit: onSubmit, onPlainKey: onPlainKey, onBinding: onBinding, session: session)
            }
            .onAppear { controller?.session = session; controller?.fallbackText = nil }
        } else {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...maxLines)
                .focused($fallbackFocus)
                .accessibilityIdentifier(accessibilityID ?? "")
                .padding(.horizontal, textInset.left)
                .padding(.vertical, textInset.top)
                .onAppear { controller?.session = nil; controller?.fallbackText = $text }
                .onChange(of: focused?.wrappedValue ?? false) { _, wants in
                    if fallbackFocus != wants { fallbackFocus = wants }
                }
                .onChange(of: fallbackFocus) { _, now in
                    guard let focused, focused.wrappedValue != now else { return }
                    if keepsFocus, !now, focused.wrappedValue {
                        // 親の意図が残っているのに外れた(再描画・シート・メニュー)→ 次のランループで戻す
                        Task { @MainActor in fallbackFocus = true }
                        return
                    }
                    focused.wrappedValue = now
                }
        }
    }

    @FocusState private var fallbackFocus: Bool
}

/// TsukaimaComposerField の中(UITextView / TextField)にカーソル位置で文字を差し込むための取っ手。
/// 親が @StateObject で持ち、field に渡す。カーソルは外さない。
@MainActor
final class ComposerFieldController: ObservableObject {
    weak var session: HardwareIMESession?
    var fallbackText: Binding<String>?

    func insertAtCursor(_ s: String) {
        guard !s.isEmpty else { return }
        if let view = session?.textView {
            // 変換中なら先に確定してから差し込む(marked の中に入れない)
            view.apply(session!.core.commitAll())
            view.apply([.commit(s)])
            return
        }
        fallbackText?.wrappedValue.append(s)
    }
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
