import SwiftUI

/// 会話モードの最小限の状態表示(REQ-0: 見なくても使える前提。ここは「一応見れば分かる」だけの補助画面)。
/// 実際の開始・終了は声(Siri・ショートカット・アクションボタン。ConverseIntents.swift)で行う想定だが、
/// 画面からも同じ操作ができるようにボタンを置く。
struct ConverseStatusView: View {
    @ObservedObject private var engine = ConverseEngine.shared
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: iconName)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, isActive: isPulsing)
            Text(phaseLabel)
                .font(.title2.weight(.semibold))
            if let text = engine.lastReplyText, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                }
                .frame(maxHeight: 160)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
            Button {
                toggle()
            } label: {
                Text(engine.isRunning ? "会話を終える" : "会話を始める")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .accentColor)
            .padding(.horizontal, 32)
            Text("「オーバー」と言うと送信されます。開始・終了は Siri やアクションボタンからも呼べます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle() {
        errorMessage = nil
        if engine.isRunning {
            engine.stop()
        } else {
            do {
                try engine.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var isPulsing: Bool {
        switch engine.phase {
        case .working, .speaking, .accepted: return true
        default: return false
        }
    }

    private var iconName: String {
        switch engine.phase {
        case .stopped: return "waveform.slash"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .idle: return "mic.fill"
        case .accepted: return "checkmark.circle.fill"
        case .working: return "gearshape.fill"
        case .speaking: return "speaker.wave.2.fill"
        case .question: return "questionmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch engine.phase {
        case .stopped: return .secondary
        case .error: return .red
        case .speaking, .working: return .accentColor
        default: return .primary
        }
    }

    private var phaseLabel: String {
        switch engine.phase {
        case .stopped: return "会話モード: 停止中"
        case .connecting: return "つないでいます…"
        case .idle: return "待機中(「オーバー」で送信)"
        case .accepted: return "受け付けました"
        case .working: return "作業中…"
        case .speaking: return "話しています…"
        case .question: return "質問があります"
        case .error(let msg): return "エラー: \(msg)"
        }
    }
}
