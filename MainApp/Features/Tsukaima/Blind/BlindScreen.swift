import SwiftUI
import UIKit

/// 画面を見ずに使うための、ブラインドキー接続画面。
struct BlindScreen: View {
    let onClose: () -> Void

    @StateObject private var model = BlindScreenModel()
    @State private var diagnostics: [BlindKeyDiagnostic] = BlindScreen.seedDiagnostics()
    @State private var showDiagnostics = false
    @State private var showBridge = false
    @Environment(\.scenePhase) private var scenePhase

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
            Color(.systemBackground).ignoresSafeArea()
            BlindKeysHost(onEvent: model.push, onDiagnostics: { diagnostics = $0 })
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)

            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(model.statusColor)
                            .frame(width: 10, height: 10)
                        Text(model.statusText)
                            .lineLimit(1)
                            .font(.body.monospaced())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("blind.status")

                    Text(model.listenerText)
                        .lineLimit(1)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("blind.listener")
                }

                Button("閉じる", action: onClose)
                    .buttonStyle(.bordered)
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
                            Button("ESP32 ブリッジ診断") {
                                showBridge = true
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("bridge.open")
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
        .sheet(isPresented: $showBridge) {
            BridgeDiagnosticsScreen(onClose: { showBridge = false })
        }
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.ensureReplyLink() }
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
        .foregroundStyle(.primary)
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
            Text("標準の入る・出る(2回押し): カタカナひらがな(右Option)が第一候補、右Commandが第二候補。ほか 右Ctrl・F12・変換・LANG1。かな/英数: CapsLock・右Shift・無変換・LANG2。声の入切: Insert・F10・`。返事を読む: Tab長押し")
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blind.bind.list")
    }
}

@MainActor
private final class BlindScreenModel: ObservableObject {
    @Published private var linkState = BlindLink.LinkState.idle
    @Published private var blindOn = false
    @Published private var mode = "kana"
    @Published private var listenerOn: Bool?
    @Published private var replyNote: String?

    @Published private(set) var bindings: BlindBindings

    private let store: BlindBindingsStore
    private let link: BlindLink
    private let cues = BlindCueRouter(outputs: [BlindTonePlayer()])  // 振動などの出口は cues.add で足す
    private var wake = BlindWakePolicy(openedAt: ProcessInfo.processInfo.systemUptime)
    private var wakeTimer: Timer?
    private var awake = false
    /// 返事の経路(再生専用の /ws/converse)を、この画面が始めたか。閉じるときは持ち主のときだけ止める。
    private var ownsReplyLink = false

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
            if state != .open { self?.listenerOn = nil }
        }
        link.onBeep = { [weak self] beep in
            self?.cues.play(beep)
        }
        link.onListener = { [weak self] on in
            self?.listenerOn = on
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

    /// 返事の経路の表示。始められなかったときは、その理由を 1 行で出す。
    var listenerText: String {
        if let replyNote { return replyNote }
        guard let listenerOn else { return "返事の経路: 確認中" }
        return listenerOn ? "返事の経路: つながっている" : "返事の経路: つながっていない"
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
        // ブリッジ(ESP32)から届いたキーも、手元のキーと同じ経路へ流す。
        BridgeCentral.shared.onKeys = { [weak self] events in
            for event in events { self?.push(event) }
        }
        startReplyLink()
    }

    /// 返事を耳に届けるため、会話の経路を再生専用(マイクなし)でつなぐ。UI テスト(--claude-mock)では音声に触れない。
    private func startReplyLink() {
        guard !ownsReplyLink, !ProcessInfo.processInfo.arguments.contains("--claude-mock") else { return }
        do {
            ownsReplyLink = try ConverseEngine.shared.startPlaybackOnly()
            replyNote = nil
        } catch {
            ownsReplyLink = false
            let nsError = error as NSError
            replyNote = nsError.domain == "converse" ? nsError.localizedDescription : "返事は聞けません(音声を始められません)"
        }
    }

    /// 前面に戻ったとき、音声が止まっていたら再開する。
    func ensureReplyLink() {
        if !ConverseEngine.shared.isRunning {
            ownsReplyLink = false
            startReplyLink()
        } else {
            ConverseEngine.shared.ensure()
        }
    }

    func stop() {
        ConverseEngine.shared.stopIfOwned(ownsReplyLink)
        ownsReplyLink = false
        replyNote = nil
        wakeTimer?.invalidate()
        wakeTimer = nil
        BridgeCentral.shared.onKeys = nil
        link.disconnect()
        setAwake(false)
    }

    /// 起こしておく間だけ、画面を自動で消さない。それ以外は普通に消える設定へ戻す。
    private func applyWake() {
        setAwake(wake.keepAwake(now: ProcessInfo.processInfo.systemUptime))
    }

    private func setAwake(_ on: Bool) {
        guard on != awake else { return }
        awake = on
        UIApplication.shared.isIdleTimerDisabled = on
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
        BridgeCentral.shared.sendConfig()
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
