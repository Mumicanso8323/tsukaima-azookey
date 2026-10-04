import Foundation

/// 合図の出口。音のほかに、振動や Smart Band への短文などを足せるよう、差し替え・追加できる形にしておく。
@MainActor
protocol BlindCueOutput: AnyObject {
    func play(_ beep: BlindBeep)
}

/// 複数の出口へ同じ合図を流す。
@MainActor
final class BlindCueRouter {
    private var outputs: [any BlindCueOutput]

    init(outputs: [any BlindCueOutput]) {
        self.outputs = outputs
    }

    func add(_ output: any BlindCueOutput) {
        outputs.append(output)
    }

    func play(_ beep: BlindBeep) {
        for output in outputs {
            output.play(beep)
        }
    }
}

/// 画面を消さずに(最低輝度で)起こしておく期間の方針。純粋なので単体テストできる。
/// - 画面を開いてから `grace` 秒は起こしておく(右 Ctrl の 2 回押しで入るまでの猶予)。
/// - サーバーが「ブラインド中」と言っている間は起こしておく。
/// - 一度ブラインドに入ってから出たら(Esc 長押し・5 分の自動脱出など)、猶予も打ち切り、普通に消える設定へ戻す。
///   「閉じる」を押し忘れても、電池が減り続けないようにする。
struct BlindWakePolicy: Sendable {
    static let defaultGrace: TimeInterval = 300

    private(set) var blindOn = false
    private var hasBeenOn = false
    private var graceUntil: TimeInterval

    init(openedAt now: TimeInterval, grace: TimeInterval = BlindWakePolicy.defaultGrace) {
        graceUntil = now + grace
    }

    mutating func update(blindOn on: Bool) {
        if on {
            hasBeenOn = true
        } else if hasBeenOn {
            graceUntil = -.infinity
        }
        blindOn = on
    }

    func keepAwake(now: TimeInterval) -> Bool {
        blindOn || now < graceUntil
    }
}
