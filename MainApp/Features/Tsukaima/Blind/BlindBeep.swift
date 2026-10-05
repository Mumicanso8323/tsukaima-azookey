import AVFoundation
import Foundation

/// hub から届くブラインドキー用の効果音名と、その音程表。
enum BlindBeep: String, CaseIterable, Sendable {
    case sent
    case noListener = "no_listener"
    case error
    case enter
    case exit
    case kana
    case alnum
    case voiceOn = "voice_on"
    case voiceOff = "voice_off"
    case busy
    case readNone = "read_none"
    case readDenied = "read_denied"

    var tones: [(freq: Double, ms: Int)] {
        switch self {
        case .sent: [(1200, 40)]
        case .noListener: [(350, 110), (350, 110), (350, 110)]
        case .error: [(220, 350)]
        case .enter: [(660, 90), (990, 120)]
        case .exit: [(990, 90), (660, 120)]
        case .kana: [(800, 70)]
        case .alnum: [(500, 70)]
        case .voiceOn: [(400, 80), (600, 140)]
        case .voiceOff: [(600, 80), (400, 140)]
        case .busy: [(300, 120)]
        case .readNone: [(500, 60), (500, 60)]
        case .readDenied: [(300, 70), (300, 70)]
        }
    }
}

/// 小さな正弦波を合成して鳴らす、画面専用のプレーヤー。
@MainActor
final class BlindTonePlayer: BlindCueOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 44_100.0
    private var configured = false
    /// play() がこのプレーヤーとしてセッションを有効にした(stop で手放す必要がある)
    private var sessionActivated = false
    private let isSessionBusy: () -> Bool
    private let deactivate: () -> Void

    /// - isSessionBusy: 会話の音声・講義録音・返事の音声のどれかが同じセッションを使っているか(使っていれば非アクティブにしない)
    init(isSessionBusy: @escaping () -> Bool = { false },
         deactivate: @escaping () -> Void = {
             try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
         }) {
        self.isSessionBusy = isSessionBusy
        self.deactivate = deactivate
        engine.attach(player)
    }

    /// セッションを手放してよいか(純粋)。自分が有効にしていて、ほかの誰も使っていないときだけ。
    nonisolated static func shouldDeactivate(sessionActivated: Bool, conversationRunning: Bool,
                                             lectureActive: Bool, replyAudioStarted: Bool) -> Bool {
        sessionActivated && !conversationRunning && !lectureActive && !replyAudioStarted
    }

    /// テスト用: セッションを有効にしたことにする。
    func markSessionActivatedForTesting() {
        sessionActivated = true
    }

    func play(_ beep: BlindBeep) {
        configureAudioSession()
        configureEngineIfNeeded()
        guard startEngineIfNeeded() else { return }

        player.stop()
        for tone in beep.tones {
            guard let buffer = makeBuffer(freq: tone.freq, milliseconds: tone.ms) else { continue }
            player.scheduleBuffer(buffer, completionHandler: nil)
        }
        player.play()
    }

    /// 再生を止め、エンジンと音声セッションを手放す。次の play() で必要になれば取り直す。
    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
        // 一度も有効にしていなければ、または会話・講義録音・返事の音声が使っている間は、セッションに触れない
        let activated = sessionActivated
        sessionActivated = false
        guard activated, !isSessionBusy() else { return }
        deactivate()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            sessionActivated = true
        } catch {
            // 音を鳴らせない状態でも、キー送信そのものは止めない。
        }
    }

    private func configureEngineIfNeeded() {
        guard !configured else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        configured = true
    }

    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    private func makeBuffer(freq: Double, milliseconds: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let frames = max(1, Int((Double(milliseconds) / 1000) * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let fadeFrames = min(Int(sampleRate * 0.005), frames / 2)
        for frame in 0..<frames {
            let phase = 2 * Double.pi * freq * Double(frame) / sampleRate
            let gain: Double
            if fadeFrames > 0, frame < fadeFrames {
                gain = Double(frame) / Double(fadeFrames)
            } else if fadeFrames > 0, frame >= frames - fadeFrames {
                gain = Double(frames - frame - 1) / Double(fadeFrames)
            } else {
                gain = 1
            }
            samples[frame] = Float(sin(phase) * gain * 0.25)
        }
        return buffer
    }
}
