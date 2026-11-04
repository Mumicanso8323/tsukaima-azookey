import SwiftUI
import UIKit

struct BlindKeyDiagnostic: Identifiable, Equatable {
    let hid: Int
    let name: String
    let down: Bool

    var id: String { "\(hid)-\(name)" }
}

extension BlindKeyDiagnostic {
    /// 押した(down)ものだけを、hid ごとに 1 行・新しい順で返す。
    static func rows(_ all: [BlindKeyDiagnostic]) -> [BlindKeyDiagnostic] {
        var seen = Set<Int>()
        var result: [BlindKeyDiagnostic] = []
        for diagnostic in all.reversed() where diagnostic.down {
            if seen.insert(diagnostic.hid).inserted {
                result.append(diagnostic)
            }
        }
        return result
    }
}

/// キー入力だけを受ける透明な responder。すべて消費し、テキスト入力には渡さない。
final class BlindKeyCapture: UIViewController {
    var onEvent: ((BlindKeyEvent) -> Void)?
    var onDiagnostics: (([BlindKeyDiagnostic]) -> Void)?

    private(set) var diagnostics: [BlindKeyDiagnostic] = []

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        self.view = view
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    /// 画面を離れたらフォーカスを返す(入力欄などからフォーカスを奪ったままにしない)
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resignFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        emit(presses, down: true)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        emit(presses, down: false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        emit(presses, down: false)
    }

    private func emit(_ presses: Set<UIPress>, down: Bool) {
        let time = ProcessInfo.processInfo.systemUptime
        for press in presses {
            guard let key = press.key else { continue }
            let hid = Int(key.keyCode.rawValue)
            let characters = key.characters
            // 診断でも入力文字は表示しない。HID 名だけを見せる。
            let name = String(describing: key.keyCode)
            diagnostics.append(BlindKeyDiagnostic(hid: hid, name: name, down: down))
            diagnostics = Array(diagnostics.suffix(40))
            onEvent?(BlindKeyEvent(hid: hid, down: down, t: time, char: characters.isEmpty ? nil : characters))
        }
        onDiagnostics?(diagnostics)
    }
}

struct BlindKeysHost: UIViewControllerRepresentable {
    let onEvent: (BlindKeyEvent) -> Void
    let onDiagnostics: ([BlindKeyDiagnostic]) -> Void

    func makeUIViewController(context: Context) -> BlindKeyCapture {
        let controller = BlindKeyCapture()
        controller.onEvent = onEvent
        controller.onDiagnostics = onDiagnostics
        return controller
    }

    func updateUIViewController(_ controller: BlindKeyCapture, context: Context) {
        controller.onEvent = onEvent
        controller.onDiagnostics = onDiagnostics
    }
}
