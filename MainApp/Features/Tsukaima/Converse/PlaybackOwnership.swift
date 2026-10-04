import Foundation

/// 会話の経路(/ws/converse)を「だれが動かしているか」の規則。純粋なので単体テストできる。
/// - 止まっているときだけ、ブラインド画面が再生専用で始められる(始めた側が持ち主 = owned)。
/// - すでに動いていれば、ブラインド画面は何も変えず、持ち主にもならない(閉じても止めない)。
/// - 再生専用の最中に会話モードが始まったら、フルへ格上げする。格上げ後はブラインド画面の持ち主資格がなくなり、
///   ブラインドを閉じても会話は止まらない。
struct PlaybackOwnership: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case stopped
        case playbackOnly
        case full
    }

    private(set) var mode = Mode.stopped

    var isRunning: Bool { mode != .stopped }
    var isPlaybackOnly: Bool { mode == .playbackOnly }

    /// 再生専用で始める。止まっていたときだけ true(= 呼び出し側が持ち主)。
    mutating func beginPlaybackOnly() -> Bool {
        guard mode == .stopped else { return false }
        mode = .playbackOnly
        return true
    }

    /// 会話モード(フル)として動いている状態にする(新規開始・格上げの完了時に呼ぶ)。
    mutating func markFull() {
        mode = .full
    }

    /// 持ち主が閉じたとき。持ち主で、かつまだ再生専用のままのときだけ止める(true)。
    mutating func stopIfOwned(_ owned: Bool) -> Bool {
        guard owned, mode == .playbackOnly else { return false }
        mode = .stopped
        return true
    }

    /// 会話モードの停止。動いていたら true。
    mutating func stop() -> Bool {
        guard mode != .stopped else { return false }
        mode = .stopped
        return true
    }
}
