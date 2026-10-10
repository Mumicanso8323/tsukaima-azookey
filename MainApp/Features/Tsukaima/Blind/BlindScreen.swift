import SwiftUI
import UIKit

/// 画面を見ずに使うための、ブラインドキー接続画面。
/// 接続・返事の受け取り・振動・音は BlindLinkHost(アプリの寿命)が持つ。この画面はキーの取り込み(BlindKeysHost)と表示だけ。
/// 画面が消えても接続は切らない(切るのは「閉じる」だけ)。
struct BlindScreen: View {
    let onClose: () -> Void

    @StateObject private var model = BlindScreenModel()
    @ObservedObject private var host = BlindLinkHost.shared
    @EnvironmentObject private var router: AppRouter
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
            Color(.systemBackground).ignoresSafeArea()
            BlindKeysHost(onEvent: host.push, onDiagnostics: { diagnostics = $0 })
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: 20) {
                    statusSection
                    outputChips
                    Text("TEXT のとき、画面をロックすると返事は届きません(画面を開いたままにしてください)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("blind.lockNote")
                    if let note = host.conversationNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("blind.note")
                    }
                    if BlindLinkHost.isMock {
                        BlindMockControls(host: host)
                    }
                    BlindReplyCard(host: host, store: host.replyStore) {
                        router.selectedTab = .claude
                    }

                    Button("閉じる") {
                        host.disable()
                        onClose()
                    }
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
        }
        .onAppear {
            let routerRef = self.router
            host.setClaudeTabProbe {
                routerRef.selectedTab == .claude && UIApplication.shared.applicationState == .active
            }
            host.enable()
            host.markSeen()
            model.start(blindOn: host.blindOn)
        }
        .onDisappear {
            // 接続は切らない(タブを移っても返事の受け取りを続ける)。画面に結び付くのは画面を消さない設定だけ。
            model.stop()
        }
        .onChange(of: host.blindOn) { _, on in
            model.update(blindOn: on)
        }
    }

    private var statusSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .lineLimit(1)
                    .font(.body.monospaced())
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("blind.status")

            Text(listenerText)
                .lineLimit(2)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("blind.listener")
        }
    }

    private var statusText: String {
        "\(connectionText) / \(host.blindOn ? "on" : "off") / \(host.keyMode)"
    }

    private var connectionText: String {
        switch host.linkState {
        case .idle: "未接続"
        case .connecting: "接続中"
        case .open: "接続済み"
        case .reconnecting: "再接続中"
        }
    }

    private var statusColor: Color {
        switch host.linkState {
        case .open: host.blindOn ? .green : .yellow
        case .connecting, .reconnecting: .yellow
        case .idle: .gray
        }
    }

    /// 返事の経路の表示。proto 2 は path、古いサーバーは従来の聞き手の有無。始められなかったときは理由を 1 行で出す。
    private var listenerText: String {
        if let note = host.replyNote { return note }
        if host.isProto2 {
            guard let path = host.path else { return "返事の経路: 確認中" }
            return path.ok ? "返事の経路: つながっている" : "返事の経路: つながっていない"
        }
        guard let listenerOn = host.listenerOn else { return "返事の経路: 確認中" }
        return listenerOn ? "返事の経路: つながっている" : "返事の経路: つながっていない"
    }

    private var outputChips: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ForEach(BlindOutputMode.allCases, id: \.self) { chip in
                    let selected = host.effectiveMode == chip
                    Button {
                        host.setMode(chip)
                    } label: {
                        Text(chip.chipLabel)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(selected ? .blue : .gray)
                    .disabled(chip == .text && !host.textChipEnabled)
                    .accessibilityIdentifier("blind.output.\(chip.rawValue)")
                    .accessibilityValue(selected ? "selected" : "")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if let reason = host.textChipReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("blind.output.reason")
            }
        }
    }
}

extension BlindOutputMode {
    var chipLabel: String {
        switch self {
        case .voice: "声"
        case .text: "文字"
        case .both: "両方"
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
                                        host.assign(BlindBinding(action: action, hid: diagnostic.hid, style: style))
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
            if host.bindings.isEmpty {
                Text("なし")
            }
            ForEach(host.bindings.entries, id: \.self) { binding in
                HStack(spacing: 10) {
                    Text("\(BlindKeyNames.label(hid: binding.hid)) → \(binding.action.label)(\(binding.style.label))")
                    Spacer(minLength: 4)
                    Button("消す") {
                        host.unassign(hid: binding.hid)
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("blind.bind.delete.\(binding.hid)")
                }
            }
            Text("標準の入る・出る(2回押し): カタカナひらがな(右Option)が第一候補、右Commandが第二候補。ほか 右Ctrl・F12・変換・LANG1。かな/英数: CapsLock(iOS で地球儀にしていると届かない)・右Shift・無変換・LANG2。声の入切: Insert・F10・`。返事を読む: Tab長押し。返事の出し方の切り替え: 上の一覧で割り当てたキー(サーバーの既定は F11)")
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blind.bind.list")
    }
}

/// 画面を消さない設定(wake)だけを持つ。接続・返事は BlindLinkHost。
@MainActor
private final class BlindScreenModel: ObservableObject {
    private var wake = BlindWakePolicy(openedAt: ProcessInfo.processInfo.systemUptime)
    private var wakeTimer: Timer?
    private var awake = false

    func start(blindOn: Bool) {
        wake = BlindWakePolicy(openedAt: ProcessInfo.processInfo.systemUptime)
        wake.update(blindOn: blindOn)
        applyWake()
        wakeTimer?.invalidate()
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyWake() }
        }
    }

    func update(blindOn: Bool) {
        wake.update(blindOn: blindOn)
        applyWake()
    }

    func stop() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        setAwake(false)
    }

    /// 起こしておく間だけ、画面を自動で消さない。それ以外は普通に消える設定へ戻す。
    private func applyWake() {
        setAwake(wake.keepAwake(now: ProcessInfo.processInfo.systemUptime))
    }

    private func setAwake(_ on: Bool) {
        guard on != awake else { return }
        awake = on
        BlindLinkHost.shared.setScreenWantsAwake(on)  // 出口はホスト 1 か所(返事待ちの希望と合わせる)
    }
}
