import SwiftUI
import UIKit

/// 画面を見ずに使うための、ブラインドキー接続画面。
struct BlindScreen: View {
    let onClose: () -> Void

    @StateObject private var model = BlindScreenModel()
    @State private var diagnostics: [BlindKeyDiagnostic] = []
    @State private var showDiagnostics = false
    @State private var previousBrightness: CGFloat?

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            BlindKeysHost(onEvent: model.push, onDiagnostics: { diagnostics = $0 })
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)

            VStack(spacing: 20) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(model.statusColor)
                        .frame(width: 10, height: 10)
                    Text(model.statusText)
                        .lineLimit(1)
                        .font(.body.monospaced())
                }
                .foregroundStyle(.white)
                .accessibilityIdentifier("blind.status")

                Button("閉じる", action: onClose)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("blind.close")

                Button(showDiagnostics ? "キー診断を隠す" : "キー診断") {
                    showDiagnostics.toggle()
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .frame(minHeight: 44)
                .accessibilityIdentifier("blind.diag.toggle")

                if showDiagnostics {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text("\(diagnostic.hid)  \(diagnostic.name)")
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("blind.diag.list")
                }
            }
            .padding(24)
        }
        .onAppear {
            previousBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
        .onDisappear {
            model.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            if let previousBrightness {
                UIScreen.main.brightness = previousBrightness
            }
            previousBrightness = nil
        }
    }
}

@MainActor
private final class BlindScreenModel: ObservableObject {
    @Published private var linkState = BlindLink.LinkState.idle
    @Published private var blindOn = false
    @Published private var mode = "kana"

    private let link = BlindLink()
    private let tones = BlindTonePlayer()

    init() {
        link.onLinkState = { [weak self] state in
            self?.linkState = state
        }
        link.onBeep = { [weak self] beep in
            self?.tones.play(beep)
        }
        link.onState = { [weak self] state in
            self?.blindOn = state.blindOn
            self?.mode = state.mode
        }
    }

    var statusText: String {
        "\(connectionText) / \(blindOn ? "on" : "off") / \(mode)"
    }

    var statusColor: Color {
        switch linkState {
        case .open: blindOn ? .green : .yellow
        case .connecting, .reconnecting: .yellow
        case .idle: .gray
        }
    }

    func start() {
        link.connect()
    }

    func stop() {
        link.disconnect()
    }

    func push(_ event: BlindKeyEvent) {
        link.push(event)
    }

    private var connectionText: String {
        switch linkState {
        case .idle: "未接続"
        case .connecting: "接続中"
        case .open: "接続済み"
        case .reconnecting: "再接続中"
        }
    }
}
