import SwiftUI
import UIKit

/// 画面を見ずに使うための、ブラインドキー接続画面。
struct BlindScreen: View {
    let onClose: () -> Void

    @StateObject private var model = BlindScreenModel()
    @State private var diagnostics: [BlindKeyDiagnostic] = BlindScreen.seedDiagnostics()
    @State private var showDiagnostics = false

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    /// UI テスト用: --blind-mock-keys で、本物のキーが無くても診断に 1 行(右Ctrl)を出す。
    private static func seedDiagnostics() -> [BlindKeyDiagnostic] {
        guard ProcessInfo.processInfo.arguments.contains("--blind-mock-keys") else { return [] }
        return [BlindKeyDiagnostic(hid: 228, name: "keyboardRightControl", down: true)]
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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            diagnosticsSection
                            bindingsSection
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 360)
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

extension BlindScreen {
    private var diagnosticRows: [BlindKeyDiagnostic] {
        BlindKeyDiagnostic.rows(diagnostics)
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if diagnosticRows.isEmpty {
                Text("キー待ち")
            }
            ForEach(diagnosticRows) { diagnostic in
                HStack(spacing: 10) {
                    Text(BlindKeyNames.label(hid: diagnostic.hid, fallback: diagnostic.name))
                    Spacer(minLength: 4)
                    Menu("このキーを合図にする") {
                        ForEach(BlindAction.allCases, id: \.self) { action in
                            Menu(action.label) {
                                ForEach(BlindStyle.allCases, id: \.self) { style in
                                    Button(style.label) {
                                        model.assign(BlindBinding(action: action, hid: diagnostic.hid, style: style))
                                    }
                                }
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("blind.bind.set.\(diagnostic.hid)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("blind.bind.row.\(diagnostic.hid)")
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white.opacity(0.8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blind.diag.list")
    }

    private var bindingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("いまの合図")
            if model.bindings.isEmpty {
                Text("なし")
            }
            ForEach(model.bindings.entries, id: \.self) { binding in
                HStack(spacing: 10) {
                    Text("\(BlindKeyNames.label(hid: binding.hid)) → \(binding.action.label)(\(binding.style.label))")
                    Spacer(minLength: 4)
                    Button("消す") {
                        model.unassign(hid: binding.hid)
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("blind.bind.delete.\(binding.hid)")
                }
            }
            Text("標準: 右Ctrl・右Option・F12 の2回押し / CapsLock・右Shift / Insert・F10・` / Tab長押し")
                .foregroundStyle(.white.opacity(0.5))
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white.opacity(0.8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blind.bind.list")
    }
}

@MainActor
private final class BlindScreenModel: ObservableObject {
    @Published private var linkState = BlindLink.LinkState.idle
    @Published private var blindOn = false
    @Published private var mode = "kana"

    @Published private(set) var bindings: BlindBindings

    private let store: BlindBindingsStore
    private let link: BlindLink
    private let cues = BlindCueRouter(outputs: [BlindTonePlayer()])  // 振動などの出口は cues.add で足す
    private var wake = BlindWakePolicy(openedAt: ProcessInfo.processInfo.systemUptime)
    private var wakeTimer: Timer?
    private var previousBrightness: CGFloat?
    private var awake = false

    init() {
        // UI テストでは本番の保存値を触らず、毎回空の専用 suite を使う。
        let resolvedStore: BlindBindingsStore
        if ProcessInfo.processInfo.arguments.contains("--blind-mock-keys"),
           let mock = UserDefaults(suiteName: "blind.mock.ui") {
            mock.removePersistentDomain(forName: "blind.mock.ui")
            resolvedStore = BlindBindingsStore(defaults: mock)
        } else {
            resolvedStore = BlindBindingsStore()
        }
        store = resolvedStore
        bindings = resolvedStore.load()
        link = BlindLink(store: resolvedStore)
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

    func assign(_ binding: BlindBinding) {
        var updated = bindings
        guard updated.set(binding) else { return }  // 17 件目は入れない
        apply(updated)
    }

    func unassign(hid: Int) {
        var updated = bindings
        updated.remove(hid: hid)
        apply(updated)
    }

    private func apply(_ updated: BlindBindings) {
        bindings = updated
        store.save(updated)
        link.setBindings(updated)
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
