import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Web の部屋(forge など)の上の指の動きが「縦」か「はっきり横」かの規則(純粋。単体テストする)。
/// 縦寄りの動きは Web のスクロールに渡し、親(戻る・閉じる)の横スワイプは、はっきり横のときだけ始める。
enum TsukaimaSwipeIntent {
    /// 動きが判断できるまでに要る最小の移動量(pt)
    static let slop: CGFloat = 8
    /// 親の横スワイプを始めてよい最小の横移動(pt)
    static let horizontalMinimum: CGFloat = 24
    /// 縦寄りの境目: |dy| > |dx| * 0.6(縦から約 59 度以内)
    static let verticalRatio: CGFloat = 0.6
    /// はっきり横の境目: |dx| > 2 * |dy|(縦から約 63 度より横)
    static let horizontalRatio: CGFloat = 2

    enum Verdict: Equatable { case undecided, vertical, horizontal }

    /// 触り始めからの移動量(dx, dy)から意図を決める。どちらでもない斜めは、横の条件が揃うまで undecided のまま
    /// (= 親の横スワイプは始まらず、Web のスクロールが使える)。
    static func verdict(dx: CGFloat, dy: CGFloat) -> Verdict {
        let ax = abs(dx), ay = abs(dy)
        if ax > horizontalMinimum, ax > horizontalRatio * ay { return .horizontal }
        if max(ax, ay) >= slop, ay > ax * verticalRatio { return .vertical }
        return .undecided
    }
}

/// WebView の上に置く、動きの意図を見張る認識器。縦寄りと判断したら began(= 「親の戻るスワイプは失敗しろ」の合図)、
/// はっきり横なら failed(= 親の戻るスワイプが進める)。Web のスクロールとは同時に動き、タッチを奪わない。
final class VerticalIntentRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var origin: CGPoint = .zero

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.count == 1, let t = touches.first {
            origin = t.location(in: nil)
        } else {
            state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let t = touches.first else { return }
        let p = t.location(in: nil)
        switch TsukaimaSwipeIntent.verdict(dx: p.x - origin.x, dy: p.y - origin.y) {
        case .vertical: state = .began
        case .horizontal: state = .failed
        case .undecided: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = (state == .began || state == .changed) ? .cancelled : .failed
    }

    override func reset() { origin = .zero }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension UIView {
    /// この View を載せている UINavigationController(なければ nil)
    fileprivate var enclosingNavigationController: UINavigationController? {
        var r: UIResponder? = self
        while let cur = r {
            if let vc = cur as? UIViewController, let nav = vc.navigationController ?? (vc as? UINavigationController) { return nav }
            r = cur.next
        }
        return nil
    }
}

extension LangKeyWebView {
    /// 親のナビゲーションの戻るスワイプ(端の戻る・iOS 26 の画面のどこからでも戻る)が、縦寄りの動きでは始まらないようにする。
    /// 認識器の delegate は UIKit のものなので触らず、「縦と判断した認識器が began したら失敗する」依存だけを足す。
    @MainActor func installVerticalIntentGuard() {
        guard let nav = enclosingNavigationController else { return }
        let guardRecognizer: VerticalIntentRecognizer
        if let g = gestureRecognizers?.compactMap({ $0 as? VerticalIntentRecognizer }).first {
            guardRecognizer = g
        } else {
            guardRecognizer = VerticalIntentRecognizer(target: nil, action: nil)
            addGestureRecognizer(guardRecognizer)
        }
        if let pop = nav.interactivePopGestureRecognizer { pop.require(toFail: guardRecognizer) }
        if #available(iOS 26.0, *) {
            nav.interactiveContentPopGestureRecognizer?.require(toFail: guardRecognizer)
        }
    }
}
