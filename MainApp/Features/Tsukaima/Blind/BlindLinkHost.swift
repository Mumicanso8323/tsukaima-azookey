import Combine
import Foundation
import UIKit

/// /ws/blind の接続の持ち主。アプリの寿命と同じ(シングルトン)で、画面(BlindScreen)が消えても、
/// タブを移っても、ブラインドが「有効」のあいだは接続と返事の受け取り(カード・振動・音)を続ける。
/// キーの取り込み(BlindKeyCapture)は BlindScreen の中に残し、ここには持たない(Claude タブの first responder を奪わない)。
/// 「有効」= ブラインド画面を開いてから、本人が「閉じる」を押すまで(画面の出入りでは変わらない)。
@MainActor
final class BlindLinkHost: ObservableObject {
    /// UI テスト用の mock(--blind-mock-replies): 本物の WebSocket・音・振動に触れず、同じ受信経路に返事を流す。
    static var isMock: Bool { ProcessInfo.processInfo.arguments.contains("--blind-mock-replies") }

    static let shared = BlindLinkHost(dependencies: Dependencies.live())

    /// 差し替えられる部品(単体テストと UI テストの mock)。
    struct Dependencies {
        var defaults: UserDefaults
        var haptics: any BlindHaptics
        var audio: any BlindReplyAudio
        var routeSource: any BlindRouteSource
        var makeTonePlayer: () -> any BlindCueOutput
        var fullConversationRunning: () -> Bool
        var conversationChanges: AnyPublisher<Void, Never>
        var isMock: Bool
        var now: () -> Double
        var device: String

        @MainActor
        static func live() -> Dependencies {
            if BlindLinkHost.isMock {
                // 本番の保存値を触らず、毎回空の専用 suite を使う(BlindBindingsStore と同じ suite)。
                let suite = UserDefaults(suiteName: "blind.mock.ui") ?? .standard
                suite.removePersistentDomain(forName: "blind.mock.ui")
                return Dependencies(
                    defaults: suite,
                    haptics: RecordingBlindHaptics(),
                    audio: RecordingBlindReplyAudio(),
                    routeSource: FixedBlindRouteSource(.speaker),
                    makeTonePlayer: { RecordingCueOutput() },
                    fullConversationRunning: { false },
                    conversationChanges: Empty<Void, Never>().eraseToAnyPublisher(),
                    isMock: true,
                    now: { Date().timeIntervalSince1970 },
                    device: ConverseDeviceID.current()
                )
            }
            return Dependencies(
                defaults: .standard,
                haptics: SystemBlindHaptics(),
                audio: ConverseBlindReplyAudio(),
                routeSource: SystemBlindRouteSource(),
                makeTonePlayer: { BlindTonePlayer() },
                fullConversationRunning: { ConverseEngine.shared.isRunning && !ConverseEngine.shared.playbackOnly },
                conversationChanges: ConverseEngine.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                isMock: false,
                now: { Date().timeIntervalSince1970 },
                device: ConverseDeviceID.current()
            )
        }
    }

    // MARK: 画面が読む状態

    @Published private(set) var enabled = false
    @Published private(set) var linkState = BlindLink.LinkState.idle
    @Published private(set) var blindOn = false
    @Published private(set) var keyMode = "kana"
    /// ready で知らされた proto。nil = まだ知らない。1 = 古いサーバー(従来の /ws/converse 再生専用へ戻る)。
    @Published private(set) var proto: Int?
    @Published private(set) var path: BlindLink.PathState?
    @Published private(set) var heldCount = 0
    /// 古いサーバー(proto 1)のときだけ: 返事の経路(/ws/converse の聞き手)の有無。
    @Published private(set) var listenerOn: Bool?
    @Published private(set) var replyNote: String?
    @Published private(set) var mode: BlindOutputMode
    @Published private(set) var bindings: BlindBindings
    @Published private(set) var fullConversationRunning = false
    /// ホストが接続を始めた回数(画面の出入りで増えないことを UI テストが見る)。
    @Published private(set) var connectCount = 0
    /// 返事・合図・音声を処理するたびに増える(mock のデバッグ表示を更新させる)。
    @Published private(set) var debugRevision = 0

    let replyStore: BlindReplyStore
    let link: BlindLink

    // MARK: 内部

    private let deps: Dependencies
    private let bindingsStore: BlindBindingsStore
    private let modeStore: BlindOutputModeStore
    private let cues: BlindCueFactory
    private var coordinator: BlindReplyCoordinator!
    private var route: BlindRoute
    private var claudeTabProbe: () -> Bool = { false }
    private var ownsReplyLink = false
    private var mockRid = 0
    private var cancellables: Set<AnyCancellable> = []

    init(dependencies: Dependencies) {
        let bindingsStore = BlindBindingsStore(defaults: dependencies.defaults)
        let modeStore = BlindOutputModeStore(defaults: dependencies.defaults)
        let replyStore = BlindReplyStore(defaults: dependencies.defaults)
        deps = dependencies
        self.bindingsStore = bindingsStore
        self.modeStore = modeStore
        self.replyStore = replyStore
        bindings = bindingsStore.load()
        mode = modeStore.load()
        link = BlindLink(store: bindingsStore)
        route = dependencies.routeSource.current
        cues = BlindCueFactory(haptics: dependencies.haptics, makeTonePlayer: dependencies.makeTonePlayer)
        fullConversationRunning = dependencies.fullConversationRunning()

        let probes = BlindReplyCoordinator.Probes(
            sendPlayed: { [unowned self] id in self.link.sendPlayed(id: id) },
            now: dependencies.now,
            mode: { [unowned self] in self.mode },
            route: { [unowned self] in self.route },
            fullConversationRunning: { [unowned self] in self.fullConversationRunning },
            claudeTabFrontmostAndActive: { [unowned self] in self.claudeTabProbe() },
            bothHaptics: { [unowned self] in self.modeStore.loadBothHaptics() },
            proto2: { [unowned self] in self.proto == 2 }
        )
        coordinator = BlindReplyCoordinator(store: replyStore, haptics: dependencies.haptics,
                                            audio: dependencies.audio, probes: probes)
        coordinator.onAudioError = { [weak self] text in self?.replyNote = text }
        wireLink()
        wireSources()
        pushHello()
    }

    // MARK: 画面から

    /// Claude タブが前面でアプリが active のときは返事の振動を出さない(C-5)。
    func setClaudeTabProbe(_ probe: @escaping () -> Bool) {
        claudeTabProbe = probe
    }

    /// ブラインドを有効にして接続を始める。すでに有効なら何もしない(画面の出入りでつなぎ直さない)。
    func enable() {
        guard !enabled else { return }
        enabled = true
        pushHello()
        connectCount += 1
        if deps.isMock {
            linkState = .open
            link.ingestForTesting(#"{"type":"ready","proto":2,"epoch":"mock"}"#)
            link.ingestForTesting(#"{"type":"path","ok":true,"busy":false,"audio_owner":"none"}"#)
        } else {
            link.connect()
        }
    }

    /// 「閉じる」: 接続も、(古いサーバーのときの)再生専用の経路も止める。
    func disable() {
        guard enabled else { return }
        enabled = false
        if !deps.isMock { link.disconnect() }
        stopLegacyReplyLink()
        coordinator.stopAudio()
        linkState = .idle
        proto = nil
        path = nil
        heldCount = 0
        listenerOn = nil
        replyNote = nil
        debugRevision += 1
    }

    func push(_ event: BlindKeyEvent) {
        link.push(event)
    }

    func markSeen() {
        replyStore.markSeen()
    }

    // 合図のキーの割り当て
    func assign(_ binding: BlindBinding) {
        var updated = bindings
        guard updated.set(binding) else { return }  // 17 件目は入れない
        applyBindings(updated)
    }

    func unassign(hid: Int) {
        var updated = bindings
        updated.remove(hid: hid)
        applyBindings(updated)
    }

    private func applyBindings(_ updated: BlindBindings) {
        bindings = updated
        bindingsStore.save(updated)
        link.setBindings(updated)
    }

    // MARK: 出し方

    /// 古いサーバー(proto 1)では TEXT を実現できない(音が出る事故になる)ので、チップを無効にする。
    var textChipEnabled: Bool { proto != 1 }

    var textChipReason: String? {
        proto == 1 ? "TEXT は新しいサーバーが必要です(いまは声で返事します)" : nil
    }

    /// 実際に使う出し方。古いサーバーでは保存値に関わらず従来の VOICE。
    var effectiveMode: BlindOutputMode { proto == 1 ? .voice : mode }

    /// 会話モード(声)が同じ端末で動いているのに TEXT のとき、1 行の注意(RISK-9)。
    var conversationNote: String? {
        mode == .text && fullConversationRunning ? "会話モードの声は止まりません" : nil
    }

    /// 画面のチップでの切り替え。その場で反映・保存し、proto 2 ならサーバーにも伝える。
    func setMode(_ newMode: BlindOutputMode) {
        guard newMode != mode, !(newMode == .text && proto == 1) else { return }
        apply(mode: newMode, cue: false)
        if proto == 2 { link.sendOutputSet(newMode) }
    }

    private func apply(mode newMode: BlindOutputMode, cue: Bool) {
        mode = newMode
        modeStore.save(newMode)
        coordinator.modeChanged(to: newMode)
        pushHello()
        if cue { cues.playModeCue(for: newMode) }
        debugRevision += 1
    }

    // MARK: mock(UI テスト)

    /// 本物のサーバーから届いたことにして、同じ受信経路に流す。
    func inject(mockJSON text: String) {
        guard deps.isMock else { return }
        link.ingestForTesting(text)
    }

    func sendMockReply(text: String? = nil, repeatLast: Bool = false) {
        if !repeatLast { mockRid += 1 }
        let body = text ?? "モックの返事 \(mockRid)"
        let object: [String: Any] = [
            "type": "reply", "rid": mockRid, "epoch": "mock", "text": body, "question": false,
            "at": deps.now(), "origin": "claude_tab", "replay": false, "audio": "none", "why": "text",
        ]
        if let json = BlindJSON.encode(object) { inject(mockJSON: json) }
    }

    /// 画面に結び付かない遅延(Blind 画面が見えていない間の受信を確かめる)。
    func delayedMockReply(after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.sendMockReply(text: "遅れて届いた返事")
        }
    }

    var debugHaptics: [String] {
        (deps.haptics as? RecordingBlindHaptics)?.played.map(\.rawValue) ?? []
    }

    var debugAudioStarts: Int { deps.audio.startCount }
    var debugTonePlayers: Int { cues.tonePlayersCreated }

    // MARK: 配線

    private func wireLink() {
        link.onLinkState = { [weak self] state in
            guard let self else { return }
            if self.deps.isMock { return }  // mock は enable() で .open に固定
            self.linkState = state
            if state != .open {
                // @Published は同値でも通知するので、変わるときだけ代入して画面(開いているメニュー)を再描画させない
                if self.listenerOn != nil { self.listenerOn = nil }
                if self.path != nil { self.path = nil }
            }
        }
        link.onReady = { [weak self] serverProto, _ in
            self?.handleReady(proto: serverProto)
        }
        link.onBeep = { [weak self] beep in
            self?.handleBeep(beep)
        }
        link.onListener = { [weak self] on in
            self?.listenerOn = on
        }
        link.onState = { [weak self] state in
            self?.blindOn = state.blindOn
            self?.keyMode = state.mode
        }
        link.onReply = { [weak self] reply in
            self?.handleReply(reply)
        }
        link.onOutput = { [weak self] serverMode in
            guard let self, serverMode != self.mode else { return }
            self.apply(mode: serverMode, cue: true)  // 別の経路(キー)での切り替え。合図を出す
        }
        link.onPath = { [weak self] path in
            self?.path = path
        }
        link.onHeld = { [weak self] count in
            self?.heldCount = count
        }
        link.onAudio = { [weak self] header, data in
            guard let self else { return }
            self.coordinator.handleAudio(header: header, data: data)
            self.debugRevision += 1
        }
    }

    private func wireSources() {
        deps.routeSource.onChange = { [weak self] newRoute in
            guard let self else { return }
            self.route = newRoute
            self.pushHello()
            self.link.sendRoute(newRoute)
        }
        deps.conversationChanges
            .sink { [weak self] _ in
                // objectWillChange は変更の直前に飛ぶので、1 拍おいて読む
                Task { @MainActor [weak self] in self?.refreshConversationState() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.appBecameActive() }
            }
            .store(in: &cancellables)
    }

    private func refreshConversationState() {
        let running = deps.fullConversationRunning()
        guard running != fullConversationRunning else { return }
        fullConversationRunning = running
        if running { coordinator.stopAudio() }  // 同じ端末で AVAudioEngine を 2 つ鳴らさない
        pushHello()
        link.sendCaps(audio: BlindAudioGate.capsAudio(fullConversationRunning: running))
    }

    private func appBecameActive() {
        guard enabled, !deps.isMock, proto == 1 else { return }
        ensureLegacyReplyLink()
    }

    private func pushHello() {
        let marker = coordinator?.lastMarker ?? (epoch: "", rid: 0)
        link.setHello(BlindHelloState(
            device: deps.device,
            audio: BlindAudioGate.capsAudio(fullConversationRunning: fullConversationRunning),
            output: mode,
            route: route,
            lastEpoch: marker.epoch,
            lastRid: marker.rid
        ))
    }

    // MARK: 受信

    private func handleReady(proto serverProto: Int?) {
        let known = serverProto == 2 ? 2 : 1
        proto = known
        if known == 2 {
            stopLegacyReplyLink()
            replyNote = nil
        } else {
            startLegacyReplyLink()  // 古いサーバー: 従来の /ws/converse 再生専用へ戻る
        }
        debugRevision += 1
    }

    private func handleReply(_ reply: BlindReply) {
        let outcome = coordinator.handle(reply: reply)
        if outcome == .shown { pushHello() }
        debugRevision += 1
    }

    private func handleBeep(_ beep: BlindBeep) {
        if beep == .readDenied {
            // 「読めない」は出し方に関わらず振動で知らせる。ここは前面のキー操作の結果なので抑止しない。
            deps.haptics.play(.cannotRead)
        } else {
            cues.router(for: effectiveMode).play(beep)
        }
        debugRevision += 1
    }

    // MARK: 古いサーバー(proto 1)への戻り先

    /// 返事を耳に届けるため、会話の経路を再生専用(マイクなし)でつなぐ。UI テスト(--claude-mock)では音声に触れない。
    private func startLegacyReplyLink() {
        guard enabled, !ownsReplyLink, !ProcessInfo.processInfo.arguments.contains("--claude-mock") else { return }
        do {
            ownsReplyLink = try ConverseEngine.shared.startPlaybackOnly()
            replyNote = nil
        } catch {
            ownsReplyLink = false
            let nsError = error as NSError
            replyNote = nsError.domain == "converse" ? nsError.localizedDescription : "返事は聞けません(音声を始められません)"
        }
    }

    private func ensureLegacyReplyLink() {
        if !ConverseEngine.shared.isRunning {
            ownsReplyLink = false
            startLegacyReplyLink()
        } else {
            ConverseEngine.shared.ensure()
        }
    }

    private func stopLegacyReplyLink() {
        ConverseEngine.shared.stopIfOwned(ownsReplyLink)
        ownsReplyLink = false
    }
}
