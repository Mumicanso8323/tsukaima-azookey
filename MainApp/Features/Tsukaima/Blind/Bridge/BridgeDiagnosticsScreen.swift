import SwiftUI

/// TEST-4 用: 前面以外で受けたときに、すでに音声のセッションが生きている場合だけ短い合図音を試す。音声は自分では始めない。
@MainActor
private final class BridgeDiagnosticsModel: ObservableObject {
    @Published var recordLocked = false {
        didSet { applyCue() }
    }

    private lazy var player = BlindTonePlayer()

    func applyCue() {
        if recordLocked {
            BridgeCentral.shared.cueAttempt = { [weak self] in self?.attemptCue() ?? .skipped }
        } else {
            BridgeCentral.shared.cueAttempt = nil
        }
    }

    func detach() {
        BridgeCentral.shared.cueAttempt = nil
    }

    private func attemptCue() -> BridgeCue {
        guard ConverseEngine.shared.isRunning else { return .skipped }
        return player.playChecked(.sent) ? .ok : .fail
    }
}

/// ESP32 ブリッジの診断画面(TEST-3 / TEST-4)。キーの名前は出さない。
struct BridgeDiagnosticsScreen: View {
    let onClose: () -> Void

    @ObservedObject private var bridge = BridgeCentral.shared
    @StateObject private var model = BridgeDiagnosticsModel()

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("ESP32 ブリッジ診断").font(.headline)
                    Spacer()
                    Button("閉じる", action: onClose)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("bridge.close")
                }

                Toggle("ブリッジを使う(開始・停止)", isOn: Binding(
                    get: { bridge.isRunning },
                    set: { $0 ? bridge.start() : bridge.stop() }
                ))
                .accessibilityIdentifier("bridge.toggle")

                if let probe = bridge.kbState.probeResult {
                    Text(probe)
                        .font(.headline)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellow.opacity(0.3))
                        .accessibilityIdentifier("bridge.probe")
                }
                statusSection
                pinSection
                test3Section
                test4Section
                packetsSection
            }
            .padding(20)
        }
        .onDisappear { model.detach() }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func yesNo(_ value: Bool?) -> String {
        guard let value else { return "不明" }
        return value ? "はい" : "いいえ"
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            line("Bluetooth", bridge.bluetooth.label)
            line("探している", yesNo(bridge.scanning))
            line("つながっている", yesNo(bridge.connected))
            line("購読している", yesNo(bridge.subscribed))
            line("キーボード", bridge.kbState.label)
            line("ブラインド(ESP32 側)", yesNo(bridge.blind))
            line("HID ゲート(ESP32 側)", yesNo(bridge.hidGate))
            line("電池", bridge.battery.map { "\($0)%" } ?? "不明")
            line("欠落したパケット", "\(bridge.missedPackets)")
            line("上限超えで捨てた数", "\(bridge.rateDropped)")
            line("最後の受信", bridge.lastReceipt.map { $0.formatted(date: .omitted, time: .standard) } ?? "なし")
        }
        .font(.caption.monospaced())
        .accessibilityIdentifier("bridge.status")
    }

    private var pinSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pinned = bridge.pinnedID {
                Text("接続先: 固定済み(識別子の末尾 \(String(pinned.uuidString.suffix(4))))")
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("bridge.pinned")
            } else {
                Text("接続先: 未固定(下の一覧から選ぶまで、自動ではつながりません)")
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("bridge.pinned")
                Text("見つかった機器")
                    .font(.caption)
                if bridge.discovered.isEmpty { Text("まだ見つかっていません").font(.caption2).foregroundStyle(.secondary) }
                ForEach(bridge.discovered) { item in
                    HStack {
                        Text("\(item.name) / RSSI \(item.rssi) / …\(item.shortID)")
                            .font(.caption.monospaced())
                        Spacer(minLength: 4)
                        Button("この機器につなぐ") { bridge.pin(item.id) }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("bridge.pin.\(item.shortID)")
                    }
                }
            }
            Button("固定を解除して記録も消す") { bridge.unpin() }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("bridge.unpin")
            Button("記録を消す") { bridge.clearRecords() }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("bridge.clearLog")
        }
    }

    private var test3Text: String {
        var text = "TEST-3: "
        if bridge.subscribed {
            text += "見つかった / つながった / 購読できた"
        } else if bridge.connected {
            text += "見つかった / つながった"
        } else if bridge.found {
            text += "見つかった"
        } else {
            text += "まだ見つからない"
        }
        if bridge.foundViaRetrieveConnected {
            text += "(iOS が HID として持っている状態で取得できた)"
        }
        return text
    }

    private var test3Section: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(test3Text)
                .font(.caption.monospaced())
                .accessibilityIdentifier("bridge.test3.text")
            Button("TEST-3 をやり直す(止めて始め直す)") {
                bridge.stop()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { BridgeCentral.shared.start() }
                }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("bridge.test3")
            Button("設定を送り直す") {
                bridge.sendConfig()
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("bridge.sendConfig")
        }
    }

    private var test4Section: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("ロック中の受信を記録(合図音も試す)", isOn: $model.recordLocked)
                .accessibilityIdentifier("bridge.test4")
            Text("オンにして画面をロックし、1 分ほど打ってから解除すると、下に結果が出ます。合図音は、会話の音声がすでに動いているときだけ試します(自分では音声を始めません)。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(BridgeLockSummary(records: bridge.records).text)
                .font(.caption.monospaced())
                .accessibilityIdentifier("bridge.test4.summary")
        }
    }

    private var packetsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("直近 20 件(新しい順)")
            if bridge.records.isEmpty { Text("まだ受信なし") }
            ForEach(bridge.records.suffix(20).reversed()) { record in
                Text("#\(record.seq) \(record.down ? "押" : "離") \(record.appState.label) \(record.deltaMs.map { "+\($0)ms" } ?? "-") cue=\(record.cue.rawValue)")
            }
        }
        .font(.caption.monospaced())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.packets")
    }
}
