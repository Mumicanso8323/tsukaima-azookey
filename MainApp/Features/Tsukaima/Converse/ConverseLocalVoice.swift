import AVFoundation

/// 端末側の読み上げ(AVSpeechSynthesizer・日本語)。サーバーの声(wav)が作れなかった時・回線が無い時の予備
/// (A2・A3・A4。docs/convmode-robustness-2026-10-28.md)。
/// usesApplicationAudioSession のまま(既定 true)なので、会話モード中は ConverseAudioIO の
/// セッション(.playAndRecord・.voiceChat)と同じ経路から出る。読んでいる間だけ `onBusy(true)` を呼び、
/// 呼び出し側が ducking を掛ける。main スレッド専用。
final class ConverseLocalVoice: NSObject, AVSpeechSynthesizerDelegate {
    var onBusy: ((Bool) -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var queued = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        AudioDiag.logWithApp("audio localvoice speak chars=\(t.count)")
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        if queued == 0 { onBusy?(true) }
        queued += 1
        synth.speak(u)
    }

    /// 会話モードを止めるとき
    func stop() {
        synth.stopSpeaking(at: .immediate)
        if queued > 0 { queued = 0; onBusy?(false) }
    }

    private func finished() {
        queued = max(0, queued - 1)
        if queued == 0 { onBusy?(false) }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished() }
}
