import Foundation
import UIKit

/// 振動の型。音(BlindBeep)の代わりに TEXT で使う。
enum BlindHapticPattern: String, Equatable, Sendable {
    case reply            // 返事の到着(通知型 1 回)
    case replyQuestion    // 返事が質問(2 回)
    case cannotRead       // 読めない・今は無い(短く 2 回)
    case modeText         // TEXT に切り替えた(2 回)
    case modeBoth         // BOTH に切り替えた(1 回)
    case sent             // 送れた(軽く 1 回)
    case error            // 失敗(強く 3 回)
    case enter
    case exit
    case soft             // かな/英数・声の入切など

    /// 音の合図に対応する振動。
    static func pattern(for beep: BlindBeep) -> BlindHapticPattern {
        switch beep {
        case .sent: return .sent
        case .error: return .error
        case .enter: return .enter
        case .exit: return .exit
        case .noListener, .busy, .readNone, .readDenied: return .cannotRead
        case .kana, .alnum, .voiceOn, .voiceOff: return .soft
        }
    }
}

/// 振動の出口。注入できるようにして、テストでは呼び出しを記録する。
@MainActor
protocol BlindHaptics: AnyObject {
    func play(_ pattern: BlindHapticPattern)
}

/// UIKit の触覚フィードバック。前面のときだけ意味がある(ロック中・背景では出ない)。
@MainActor
final class SystemBlindHaptics: BlindHaptics {
    private enum Pulse {
        case notify(UINotificationFeedbackGenerator.FeedbackType)
        case impact(UIImpactFeedbackGenerator.FeedbackStyle)
    }

    func play(_ pattern: BlindHapticPattern) {
        let steps = Self.steps(for: pattern)
        for (index, step) in steps.enumerated() {
            let delay = step.delay
            if index == 0 {
                fire(step.pulse)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.fire(step.pulse)
                }
            }
        }
    }

    private func fire(_ pulse: Pulse) {
        switch pulse {
        case .notify(let type):
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(type)
        case .impact(let style):
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    private static func steps(for pattern: BlindHapticPattern) -> [(pulse: Pulse, delay: TimeInterval)] {
        switch pattern {
        case .reply:
            return [(.notify(.success), 0)]
        case .replyQuestion:
            return [(.notify(.success), 0), (.notify(.warning), 0.22)]
        case .cannotRead:
            return [(.impact(.light), 0), (.impact(.light), 0.12)]
        case .modeText:
            return [(.impact(.medium), 0), (.impact(.medium), 0.14)]
        case .modeBoth:
            return [(.impact(.medium), 0)]
        case .sent:
            return [(.impact(.light), 0)]
        case .error:
            return [(.impact(.heavy), 0), (.impact(.heavy), 0.12), (.impact(.heavy), 0.24)]
        case .enter:
            return [(.impact(.light), 0), (.impact(.medium), 0.12)]
        case .exit:
            return [(.impact(.medium), 0), (.impact(.light), 0.12)]
        case .soft:
            return [(.impact(.soft), 0)]
        }
    }
}

/// 呼び出しを記録するだけの振動(単体テストと UI テストの mock 用)。
@MainActor
final class RecordingBlindHaptics: BlindHaptics {
    private(set) var played: [BlindHapticPattern] = []

    func play(_ pattern: BlindHapticPattern) {
        played.append(pattern)
    }
}

/// 返事の到着で振動するか・どの型かを決める純粋な規則(DEC-8 / C-5)。
enum BlindHapticDecision {
    /// 再送の返事で、これより古いものは振動させない(DEC-13: 30 分)。
    /// 経過は「端末の now − サーバーの reply.at」で測るので、端末とサーバーの時計のずれで誤差が出る。
    /// サーバーは再送を 30 分以内のものに絞って送るため、ここは二重の安全でしかない。そこで、ずれを許す余裕(5 分)を足して、
    /// ずれのせいで新しい再送を黙らせないようにする(サーバーは変えない)。
    static let replayWindowSeconds: Double = 30 * 60
    static let clockSkewAllowanceSeconds: Double = 5 * 60
    static let replayMaxAgeSeconds: Double = replayWindowSeconds + clockSkewAllowanceSeconds

    static func replyPattern(
        reply: BlindReply,
        mode: BlindOutputMode,
        bothHaptics: Bool,
        claudeTabFrontmostAndActive: Bool,
        now: Double
    ) -> BlindHapticPattern? {
        switch mode {
        case .voice: return nil
        case .both: if !bothHaptics { return nil }
        case .text: break
        }
        if reply.replay, now - reply.at > replayMaxAgeSeconds { return nil }
        if claudeTabFrontmostAndActive { return nil }
        return reply.question ? .replyQuestion : .reply
    }
}
