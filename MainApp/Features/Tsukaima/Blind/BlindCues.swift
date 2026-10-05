import Foundation

/// 合図を振動に置き換える出口(TEXT で使う)。BlindTonePlayer と違い、音声セッションには一切触れない。
@MainActor
final class HapticCueOutput: BlindCueOutput {
    private let haptics: any BlindHaptics

    init(haptics: any BlindHaptics) {
        self.haptics = haptics
    }

    func play(_ beep: BlindBeep) {
        haptics.play(BlindHapticPattern.pattern(for: beep))
    }
}

/// 出し方から合図の出口を組む(DEC-8)。
/// - TEXT: 振動だけ。BlindTonePlayer は**作らない**(作ると AVAudioSession を触る)。
/// - VOICE: BlindTonePlayer だけ(従来どおり)。
/// - BOTH: 両方。
/// BlindTonePlayer は最初に必要になったときに 1 度だけ作る(`tonePlayersCreated` でテストが数える)。
@MainActor
final class BlindCueFactory {
    private let haptics: any BlindHaptics
    private let makeTonePlayer: () -> any BlindCueOutput
    private var tone: (any BlindCueOutput)?
    private var hapticOutput: HapticCueOutput?
    private(set) var tonePlayersCreated = 0

    init(haptics: any BlindHaptics, makeTonePlayer: @escaping () -> any BlindCueOutput) {
        self.haptics = haptics
        self.makeTonePlayer = makeTonePlayer
    }

    private func tonePlayer() -> any BlindCueOutput {
        if let tone { return tone }
        let made = makeTonePlayer()
        tonePlayersCreated += 1
        tone = made
        return made
    }

    private func hapticCue() -> HapticCueOutput {
        if let hapticOutput { return hapticOutput }
        let made = HapticCueOutput(haptics: haptics)
        hapticOutput = made
        return made
    }

    func outputs(for mode: BlindOutputMode) -> [any BlindCueOutput] {
        switch mode {
        case .text: return [hapticCue()]
        case .voice: return [tonePlayer()]
        case .both: return [tonePlayer(), hapticCue()]
        }
    }

    func router(for mode: BlindOutputMode) -> BlindCueRouter {
        BlindCueRouter(outputs: outputs(for: mode))
    }

    /// 出し方が切り替わったときの合図。TEXT に入った瞬間は音を一切鳴らさない。
    func playModeCue(for mode: BlindOutputMode) {
        switch mode {
        case .text:
            haptics.play(.modeText)
        case .voice:
            tonePlayer().play(.voiceOn)
        case .both:
            tonePlayer().play(.voiceOn)
            haptics.play(.modeBoth)
        }
    }
}

/// UI テストの mock 用: 鳴らさず、数えるだけの合図出口。
@MainActor
final class RecordingCueOutput: BlindCueOutput {
    private(set) var played: [BlindBeep] = []

    func play(_ beep: BlindBeep) {
        played.append(beep)
    }
}
