import AVFoundation

/// 会話モードの「本人に伝えたいこと」を端末内の読み上げ(AVSpeechSynthesizer)で言う。
/// 外部サービスには何も送らない。サーバーの声(返事)とは別の、アプリ自身の警告用。
final class ConverseNoticeSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private var completion: (() -> Void)?
    private var token = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    /// main スレッドから呼ぶ。読み終えたら(または 12 秒で)completion を main で 1 回呼ぶ。
    func say(_ text: String, completion: (() -> Void)? = nil) {
        AudioDiag.log("audio notice say=\(text)")
        token += 1
        let mine = token
        self.completion = completion
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        u.volume = 1
        synth.speak(u)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.token == mine else { return }
            self.finish()
        }
    }

    private func finish() {
        let c = completion
        completion = nil
        c?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }
}
