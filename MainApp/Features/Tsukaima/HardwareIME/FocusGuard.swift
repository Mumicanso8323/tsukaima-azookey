import GameController
import SwiftUI
import UIKit

/// FocusGuard が「戻す / 待つ / あきらめる」を決めるための入力。判定を純関数にして単体テストできるようにする。
struct FocusGuardInputs: Equatable {
    /// 物理キーボードが繋がっているか(その場で GCKeyboard を読んだ値)
    var hardwareAttached = true
    /// この入力欄が「戻してほしい」状態か(本人が触った、または戻す対象のまま外れた)
    var wantsFocus = true
    /// 戻す回数が多すぎて止めている(サーキットブレーカ)
    var tripped = false
    /// 別の入力欄にフォーカスが移っている(本人が別の欄を選んだ)
    var otherIsFirstResponder = false
    /// 別の入力欄が画面に出ている(入力欄が 1 つではない)
    var otherInputVisible = false
    var inWindow = true
    var sceneActive = true
    var windowIsKey = true
    /// シート・アラート・全画面カバーなどが出ている
    var modalPresented = false
    /// 接続・切断の直後(Bluetooth の入れ替わりで暴れないよう少し待つ)
    var settling = false
}

enum FocusGuardDecision: Equatable {
    case restore
    /// 条件が整うまで待つ(時間で再判定する)
    case wait
    /// 画面に戻ってきたとき(didMoveToWindow)に判定し直す
    case waitForWindow
    case abandon
}

enum FocusGuardPolicy {
    static func decide(_ i: FocusGuardInputs) -> FocusGuardDecision {
        if !i.wantsFocus || i.tripped { return .abandon }
        // 接続が切れたら固定を直ちに解く
        if !i.hardwareAttached { return .abandon }
        // 本人が別の入力欄を選んだ、または入力欄が複数ある画面では戻さない
        if i.otherIsFirstResponder || i.otherInputVisible { return .abandon }
        if !i.inWindow { return .waitForWindow }
        if !i.sceneActive || !i.windowIsKey || i.modalPresented || i.settling { return .wait }
        return .restore
    }
}

/// 物理キーボード接続中、入力欄が画面に 1 つだけのとき、本人の操作によらず外れたフォーカスを戻す。
///
/// - 拒否(canResignFirstResponder)はしない。別の欄へ移る・キーボードを閉じる・シートを出す、を妨げないため。
/// - 戻すのは becomeFirstResponder だけ。未確定の文字・選択範囲には触れない。
/// - 本人の操作かどうかはタッチの有無では見分けない(未確認の手掛かりに頼らない)。入力欄が 1 つなら、
///   本人が移る先が無いので、外れたものは戻してよい。
/// - 戻す回数には上限がある(Bluetooth の入れ替わりなどで暴れない)。次に本人が欄を触るまで止める。
@MainActor
final class FocusGuard: ObservableObject {
    static let shared = FocusGuard()

    /// UI テスト専用(`--claude-hw-keyboard`): 物理キーボードが繋がっているものとして扱う。本番では常に false。
    nonisolated static let forcedHardwareKeyboard = ProcessInfo.processInfo.arguments.contains("--claude-hw-keyboard")
    /// UI テスト専用(`--claude-no-hw-keyboard`): 物理キーボードが無いものとして扱う(CI のシミュレータは Mac のキーボードが見える)。
    nonisolated static let forcedNoHardwareKeyboard = ProcessInfo.processInfo.arguments.contains("--claude-no-hw-keyboard")
    nonisolated static var hardwareAttached: Bool {
        if forcedHardwareKeyboard { return true }
        if forcedNoHardwareKeyboard { return false }
        return GCKeyboard.coalesced != nil
    }

    /// 戻した回数(UI テストの札用)
    @Published private(set) var restoredCount = 0
    /// 直近の判定とその入力(UI テストの札用。切り分けのため)
    @Published private(set) var lastDecision = "none"

    private weak var pending: HardwareIMETextView?
    private var generation = 0
    private var restoreTimes: [TimeInterval] = []
    private var tripped = false
    private var restoring = false
    private var lastConnectionChange: TimeInterval = -.infinity
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    static let settleSeconds: TimeInterval = 1.0
    static let retryInterval: TimeInterval = 0.5
    static let maxRestores = 3
    static let restoreWindow: TimeInterval = 5.0

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FocusGuard.shared.lastConnectionChange = ProcessInfo.processInfo.systemUptime }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FocusGuard.shared.schedule(after: 0.2) }
        })
    }

    // MARK: - 入力欄からの通知

    /// 入力欄が編集を始めた(本人が触った、またはこちらが戻した)。
    func didBegin(_ view: HardwareIMETextView) {
        view.guardWantsFocus = true
        if !restoring {
            // 本人が触ったので、止めていたものを再開する
            tripped = false
            restoreTimes.removeAll()
        }
    }

    /// 入力欄の編集が終わった。`intentional` はアプリ側が意図して外した場合(戻さない)。
    func didEnd(_ view: HardwareIMETextView, intentional: Bool) {
        guard view.pinsFocus else { return }
        if intentional {
            view.guardWantsFocus = false
            return
        }
        pending = view
        schedule(after: 0.05)
    }

    /// 入力欄が画面に載った(タブを戻ってきた・シートを閉じた後など)。
    func didMoveToWindow(_ view: HardwareIMETextView) {
        guard view.pinsFocus, view.window != nil, view.guardWantsFocus, !view.isFirstResponder else { return }
        pending = view
        schedule(after: 0.1)
    }

    // MARK: - 判定

    private func schedule(after delay: TimeInterval) {
        guard pending != nil else { return }
        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                self.evaluate()
            }
        }
    }

    private func evaluate() {
        guard let view = pending else { return }
        let inputs = Self.inputs(for: view, lastConnectionChange: lastConnectionChange, tripped: tripped)
        let decision = FocusGuardPolicy.decide(inputs)
        lastDecision = "\(decision) \(inputs)"
        switch decision {
        case .restore:
            pending = nil
            restore(view)
        case .wait:
            schedule(after: Self.retryInterval)
        case .waitForWindow:
            break
        case .abandon:
            if inputs.otherIsFirstResponder || !inputs.hardwareAttached || inputs.otherInputVisible {
                view.guardWantsFocus = false
            }
            pending = nil
        }
    }

    private func restore(_ view: HardwareIMETextView) {
        let now = ProcessInfo.processInfo.systemUptime
        restoreTimes = restoreTimes.filter { now - $0 < Self.restoreWindow }
        if restoreTimes.count >= Self.maxRestores {
            tripped = true
            view.guardWantsFocus = false
            return
        }
        restoreTimes.append(now)
        restoring = true
        let ok = view.becomeFirstResponder()
        restoring = false
        if ok { restoredCount += 1 }
    }

    /// UI テスト専用: システムが入力欄のフォーカスを奪った状況を作る(アプリが意図した resign ではない)。
    static func debugForceLoss() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                func walk(_ v: UIView) {
                    if let tv = v as? HardwareIMETextView, tv.isFirstResponder { _ = tv.resignFirstResponder() }
                    for s in v.subviews { walk(s) }
                }
                walk(window)
            }
        }
    }

    static func inputs(for view: HardwareIMETextView, lastConnectionChange: TimeInterval, tripped: Bool) -> FocusGuardInputs {
        var i = FocusGuardInputs()
        i.hardwareAttached = hardwareAttached
        i.wantsFocus = view.guardWantsFocus
        i.tripped = tripped
        i.inWindow = view.window != nil
        i.sceneActive = UIApplication.shared.applicationState == .active
        i.settling = ProcessInfo.processInfo.systemUptime - lastConnectionChange < settleSeconds
        if let window = view.window {
            i.windowIsKey = window.isKeyWindow
            i.modalPresented = hasPresentedViewController(window)
            let others = textInputs(in: window, excluding: view)
            i.otherInputVisible = !others.isEmpty
            i.otherIsFirstResponder = others.contains { $0.isFirstResponder }
        }
        return i
    }

    private static func hasPresentedViewController(_ window: UIWindow) -> Bool {
        window.rootViewController?.presentedViewController != nil
    }

    /// window の中で、見えていて編集できる入力欄(自分以外)。選択だけできる文字(isEditable == false)は数えない。
    static func textInputs(in window: UIWindow, excluding view: UIView) -> [UIView] {
        var found: [UIView] = []
        func walk(_ v: UIView) {
            if v === view { return }
            if v.isHidden || v.alpha < 0.01 { return }
            if let tv = v as? UITextView {
                if tv.isEditable, window.bounds.intersects(tv.convert(tv.bounds, to: window)) { found.append(tv) }
            } else if let tf = v as? UITextField {
                if window.bounds.intersects(tf.convert(tf.bounds, to: window)) { found.append(tf) }
            }
            for s in v.subviews { walk(s) }
        }
        walk(window)
        return found
    }
}

/// 物理キーボード接続中は、スクロールでキーボードをしまわない(入力欄のフォーカスを外さないため)。
/// 接続が切れたら公式アプリと同じ「引っぱってしまう」に戻る。
private struct HardwareAwareScrollDismiss: ViewModifier {
    @State private var attached = FocusGuard.hardwareAttached

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(attached ? .never : .interactively)
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
                attached = FocusGuard.hardwareAttached
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
                attached = FocusGuard.hardwareAttached
            }
    }
}

extension View {
    func hardwareAwareScrollDismissesKeyboard() -> some View {
        modifier(HardwareAwareScrollDismiss())
    }
}
