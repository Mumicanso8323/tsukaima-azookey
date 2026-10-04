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
    /// 別の入力欄が見えたまま待ち続けた(画面に欄が複数ある画面とみなして、戻すのをやめる)
    var waitedTooLong = false
}

enum FocusGuardDecision: Equatable {
    case restore
    /// 条件が整うまで待つ(時間で再判定する)
    case wait
    /// 画面に戻ってきたとき(didMoveToWindow)に判定し直す
    case waitForWindow
    /// 条件が整うまで何もしない(時間では再判定しない)。アクティブ化・画面への復帰・キーウィンドウの変化で判定し直す
    case idle
    case abandon
}

enum FocusGuardPolicy {
    /// 判定のあと、時間で判定し直すまでの秒数(nil なら時間では判定し直さない)。
    /// idle は、別の欄が消えても通知が来ないことがあるので、遅いポーリングで見張る(木を 1 回たどるだけで軽い)。
    static func retryDelay(for decision: FocusGuardDecision) -> TimeInterval? {
        switch decision {
        case .wait: return 0.5
        case .idle: return 2.0
        case .restore, .waitForWindow, .abandon: return nil
        }
    }

    /// 外れたのが「本人がキーボードを閉じた」ためか。ソフトウェアキーボードが出ている間に、アクティブな状態で、
    /// システム要因(画面の更新・テストが起こした喪失)でなく外れたものは、本人が閉じたものとして戻さない。
    /// 物理キーボードだけのとき(ソフトウェアキーボードが出ていない)は、外れたものはすべて戻す対象。
    static func isUserDismissal(softKeyboardVisible: Bool, sceneActive: Bool, systemLoss: Bool) -> Bool {
        softKeyboardVisible && sceneActive && !systemLoss
    }

    static func decide(_ i: FocusGuardInputs) -> FocusGuardDecision {
        if !i.wantsFocus || i.tripped { return .abandon }
        // 接続が切れたら固定を直ちに解く
        if !i.hardwareAttached { return .abandon }
        // 本人が別の入力欄を選んだ、または入力欄が複数ある画面では戻さない
        if i.otherIsFirstResponder { return .abandon }
        if !i.inWindow { return .waitForWindow }
        // シートの中の欄などは数えない。シートが閉じるまで待つ
        if !i.sceneActive || !i.windowIsKey || i.modalPresented || i.settling { return .wait }
        // 画面遷移の途中で一瞬、別の欄が見えることがある。すぐにはあきらめず、見えなくなるのを待つ。
        // 長く見えたままなら欄が複数ある画面とみなし、戻すのをやめる(意思は残すので、欄が減って画面に戻ったときに戻せる)
        if i.otherInputVisible { return i.waitedTooLong ? .idle : .wait }
        return .restore
    }
}

/// 「別の入力欄が見えていた時間」を数える。シートの表示中・非アクティブ中は数えず、見えなくなったら最初から数える。
struct OtherFieldVisibility {
    private var since: TimeInterval?

    /// - Returns: 見えたままの時間が上限を超えたか
    mutating func update(otherVisible: Bool, counting: Bool, now: TimeInterval, limit: TimeInterval) -> Bool {
        guard otherVisible, counting else {
            since = nil
            return false
        }
        if since == nil { since = now }
        return now - (since ?? now) > limit
    }
}

/// ソフトウェアキーボードが画面に出ているかの追跡。他のアプリのキーボード(Split View など)の通知は無視する。
struct SoftKeyboardTracker {
    private(set) var visible = false
    static let minimumHeight: CGFloat = 150

    /// - Parameter visibleHeight: キーボードの枠のうち、このアプリのウィンドウに重なる高さ
    mutating func willChangeFrame(isLocal: Bool, visibleHeight: CGFloat) {
        guard isLocal else { return }
        visible = visibleHeight > Self.minimumHeight
    }

    mutating func willHide(isLocal: Bool) {
        guard isLocal else { return }
        visible = false
    }

    /// 背面に回ったときは、状態が分からなくなるので「出ていない」に戻す
    /// (前面に戻って本物のソフトウェアキーボードが出れば、また通知が来る)
    mutating func reset() { visible = false }
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
    /// UI テスト専用(`--claude-soft-keyboard`): ソフトウェアキーボードが出ているものとして扱う。
    /// CI のシミュレータは「ハードウェアキーボードを接続」のため、ソフトウェアキーボードが出ない(付属バーだけ)。
    nonisolated static let forcedSoftKeyboardVisible = ProcessInfo.processInfo.arguments.contains("--claude-soft-keyboard")
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
    /// 直近の出来事(UI テストの札用。切り分けのため)
    @Published private(set) var trace: [String] = []
    fileprivate func log(_ s: String) {
        trace.append(s)
        if trace.count > 8 { trace.removeFirst() }
    }

    private weak var pending: HardwareIMETextView?
    private var otherVisibility = OtherFieldVisibility()
    private var softKeyboard = SoftKeyboardTracker()
    static let otherFieldGiveUpSeconds: TimeInterval = 10.0
    private var generation = 0
    private var restoreTimes: [TimeInterval] = []
    private var tripped = false
    private var restoring = false
    private var lastConnectionChange: TimeInterval = -.infinity
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    static let settleSeconds: TimeInterval = 1.0
    static let maxRestores = 3
    static let restoreWindow: TimeInterval = 5.0

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // ソフトウェアキーボードの旗はここでは触らない(キーボードの通知が正本。接続の変化では再通知されないことがある)
                MainActor.assumeIsolated { FocusGuard.shared.lastConnectionChange = ProcessInfo.processInfo.systemUptime }
            })
        }
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            let isLocal = (notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? true
            MainActor.assumeIsolated {
                // 画面(枠は画面の座標)ではなく、キーウィンドウと重なる高さで見る(Stage Manager・外部ディスプレイ・浮かぶキーボード)
                // キーウィンドウが無い間(アラートやウィンドウの切り替え中)は測れないので、前の値を保つ
                guard let window = FocusGuard.keyWindow else { return }
                let height = window.convert(frame, from: nil).intersection(window.bounds).height
                FocusGuard.shared.softKeyboard.willChangeFrame(isLocal: isLocal, visibleHeight: height)
            }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { notification in
            let isLocal = (notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? true
            MainActor.assumeIsolated { FocusGuard.shared.softKeyboard.willHide(isLocal: isLocal) }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FocusGuard.shared.softKeyboard.reset() }
        })
        observers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FocusGuard.shared.schedule(after: 0.2) }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FocusGuard.shared.schedule(after: 0.2) }
        })
    }

    // MARK: - 入力欄からの通知

    /// 入力欄が編集を始めた(本人が触った、またはこちらが戻した)。
    func didBegin(_ view: HardwareIMETextView) {
        log("begin pins=\(view.pinsFocus) restoring=\(restoring)")
        view.guardWantsFocus = true
        if !restoring {
            // 本人が触ったので、止めていたものを再開する
            tripped = false
            restoreTimes.removeAll()
        }
    }

    /// 入力欄の編集が終わった。`intentional` はアプリ側が意図して外した場合(戻さない)。
    func didEnd(_ view: HardwareIMETextView, intentional: Bool) {
        log("end pins=\(view.pinsFocus) intentional=\(intentional) wants=\(view.guardWantsFocus)")
        guard view.pinsFocus else { return }
        if intentional {
            view.guardWantsFocus = false
            return
        }
        // 本人がソフトウェアキーボードを閉じたもの(閉じるキー)は戻さない。次に本人が欄を触るまで止める。
        let sceneActive = UIApplication.shared.applicationState == .active
        if FocusGuardPolicy.isUserDismissal(softKeyboardVisible: softKeyboard.visible || Self.forcedSoftKeyboardVisible, sceneActive: sceneActive, systemLoss: view.guardSystemLoss) {
            log("user-dismiss")
            view.guardWantsFocus = false
            return
        }
        otherVisibility = OtherFieldVisibility()
        pending = view
        schedule(after: 0.05)
    }

    /// 入力欄が画面に載った(タブを戻ってきた・シートを閉じた後など)。
    func didMoveToWindow(_ view: HardwareIMETextView) {
        guard view.pinsFocus, view.window != nil, view.guardWantsFocus, !view.isFirstResponder else { return }
        otherVisibility = OtherFieldVisibility()
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
        var inputs = Self.inputs(for: view, lastConnectionChange: lastConnectionChange, tripped: tripped)
        // 別の欄が見えていた時間は、シートの表示中・非アクティブ中は数えない
        let counting = inputs.sceneActive && inputs.windowIsKey && !inputs.modalPresented && !inputs.settling
        inputs.waitedTooLong = otherVisibility.update(otherVisible: inputs.otherInputVisible, counting: counting,
                                                       now: ProcessInfo.processInfo.systemUptime, limit: Self.otherFieldGiveUpSeconds)
        let decision = FocusGuardPolicy.decide(inputs)
        lastDecision = "\(decision) \(inputs)"
        switch decision {
        case .restore:
            pending = nil
            otherVisibility = OtherFieldVisibility()
            restore(view)
        case .wait, .idle:
            if let delay = FocusGuardPolicy.retryDelay(for: decision) { schedule(after: delay) }
        case .waitForWindow:
            // 時間では再判定しない。画面への復帰(didMoveToWindow)で判定し直す
            break
        case .abandon:
            // 固定の意思を落とすのは、本人が別の欄を選んだとき・接続が切れたときだけ。
            // 他の欄が見えているだけの場合は、意思を残す(欄が1つに戻った後の画面復帰で戻せる)
            if inputs.otherIsFirstResponder || !inputs.hardwareAttached {
                view.guardWantsFocus = false
            }
            otherVisibility = OtherFieldVisibility()
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

    /// UI テスト専用: システムが入力欄のフォーカスを奪った状況を作る(アプリが意図した resign ではない)。奪えたら true。
    @discardableResult
    static func debugForceLoss(userDismissal: Bool = false) -> Bool {
        var lost = false
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                func walk(_ v: UIView) {
                    if let tv = v as? HardwareIMETextView, tv.isFirstResponder {
                        shared.log("force-resign")
                        tv.guardSystemLoss = !userDismissal
                        _ = tv.resignFirstResponder()
                        tv.guardSystemLoss = false
                        lost = true
                    }
                    for s in v.subviews { walk(s) }
                }
                walk(window)
            }
        }
        return lost
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    private var debugLossTimer: Timer?
    private var debugLossDone = 0
    private var debugLossIsUserDismissal = false

    /// UI テスト専用: `-claude.hwLossInterval <秒>` ごとに、入力欄にフォーカスがあれば奪う。`-claude.hwLossMax <回>` 奪えたら止まる。
    func startDebugLossIfRequested() {
        guard Self.forcedHardwareKeyboard, debugLossTimer == nil else { return }
        // 起動引数を直接読む(UserDefaults 経由だと別のテストの値が残ることがあった)
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let interval = value("-claude.hwLossInterval").flatMap(Double.init) ?? 0
        guard interval > 0 else { return }
        let maxCount = value("-claude.hwLossMax").flatMap(Int.init) ?? 0
        // -claude.hwLossKind user: 本人がキーボードを閉じたものとして外す(戻されないことの確認用)
        debugLossIsUserDismissal = value("-claude.hwLossKind") == "user"
        debugLossTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                let guardState = FocusGuard.shared
                if FocusGuard.debugForceLoss(userDismissal: guardState.debugLossIsUserDismissal) { guardState.debugLossDone += 1 }
                if maxCount > 0, guardState.debugLossDone >= maxCount { guardState.debugLossTimer?.invalidate() }
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

    /// シート・アラート・全画面カバー・ポップオーバーなどが出ているか(提示の入れ子をたどる)
    private static func hasPresentedViewController(_ window: UIWindow) -> Bool {
        var vc = window.rootViewController
        while let next = vc?.presentedViewController {
            if !next.isBeingDismissed { return true }
            vc = next
        }
        return false
    }

    /// window の中で、見えていて編集できる入力欄(自分以外)。選択だけできる文字(isEditable == false)・操作できない欄は数えない。
    /// 親の隠し(isHidden / alpha)と、クリップ(clipsToBounds)で切られた範囲も見る。
    static func textInputs(in window: UIWindow, excluding view: UIView) -> [UIView] {
        var found: [UIView] = []
        func walk(_ v: UIView, clip: CGRect) {
            if v === view { return }
            if v.isHidden || v.alpha < 0.01 { return }
            let rect = v.convert(v.bounds, to: window)
            var childClip = clip
            if v.clipsToBounds { childClip = clip.intersection(rect) }
            if let tv = v as? UITextView {
                if tv.isEditable, tv.isUserInteractionEnabled, !clip.intersection(rect).isEmpty { found.append(tv) }
            } else if let tf = v as? UITextField {
                if tf.isEnabled, tf.isUserInteractionEnabled, !clip.intersection(rect).isEmpty { found.append(tf) }
            }
            for s in v.subviews { walk(s, clip: childClip) }
        }
        walk(window, clip: window.bounds)
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
