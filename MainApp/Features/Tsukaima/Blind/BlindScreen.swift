import SwiftUI
import UIKit

/// 画面を見ずに使うための、ブラインドキー接続画面。
struct BlindScreen: View {
    let onClose: () -> Void

    @StateObject private var model = BlindScreenModel()
    @State private var diagnostics: [BlindKeyDiagnostic] = []
    @State private var showDiagnostics = false

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
                        if diagnostics.isEmpty {
                            Text("キー待ち")
                        }
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
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}

@MainActor
private final class BlindScreenModel: ObservableObject {
    @Published private var linkState = BlindLink.LinkState.idle
    @Published private var blindOn = false
    @Published private var mode = "kana"

    private let link = BlindLink()
    private let cues = BlindCueRouter(outputs: [BlindTonePlayer()])  // 振動などの出口は cues.add で足す
    private var wake = BlindWakePolicy(openedAt: ProcessInfo.processInfo.systemUptime)
    private var wakeTimer: Timer?
    private var previousBrightness: CGFloat?
    private var awake = false

    init() {
        link.onLinkState = { [weak self] state in
            self?.linkState = state
        }
        link.onBeep = { [weak self] beep in
            self?.cues.play(beep)
        }
        link.onState = { [weak self] state in
            self?.blindOn = state.blindOn
            self?.mode = state.mode
            self?.wake.update(blindOn: state.blindOn)
            self?.applyWake()
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
        wake = BlindWakePolicy(openedAt: ProcessInfo.processInfo.systemUptime)
        applyWake()
        wakeTimer?.invalidate()
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyWake() }
        }
        link.connect()
    }

    func stop() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        link.disconnect()
        setAwake(false)
    }

    /// 起こしておく間だけ、画面を消さず最低輝度にする。それ以外は普通に消える設定・元の明るさへ戻す。
    private func applyWake() {
        setAwake(wake.keepAwake(now: ProcessInfo.processInfo.systemUptime))
    }

    private func setAwake(_ on: Bool) {
        guard on != awake else { return }
        awake = on
        UIApplication.shared.isIdleTimerDisabled = on
        if on {
            previousBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0
        } else if let previousBrightness {
            UIScreen.main.brightness = previousBrightness
            self.previousBrightness = nil
        }
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
