import AVFoundation
import UIKit

/// 会話モード専用の音声入出力。TsukaimaMic(講義録音・Float32・mode=.measurement)とは別物:
/// - 入力ノードに Voice Processing(エコー消去)を有効化する(AVAudioInputNode.setVoiceProcessingEnabled)。
///   これは入出力が同じ Voice-Processing I/O ユニットを共有するため、入力側で有効にすると出力側にも効く
///   (Apple の仕様どおり)。だから再生も「同じ engine の playerNode」を通す必要がある
///   (別の AVAudioPlayer を使うとエコー消去の対象から外れる)。
/// - 送信フォーマットは converse-protocol.md 記載の PCM16LE・モノラル・16kHz(/ws/record の Float32 とは違う)。
/// - 再生中も録音を止めない(engine は録音・再生を両方持ったまま動き続ける)。
/// - スレッド: AVAudioSession / AVAudioEngine の呼び出しはすべて専用の直列キュー `aq` で行い、main では一切しない。
///   BT イヤホンが A2DP⇄HFP に切り替わる最中は setCategory・setActive・engine.start が 4〜9 秒戻らないことがあり
///   (端末ログ 11/2〜11/12 で実測)、main で呼ぶと画面が固まる。固まっている間に OS が終了を求めると
///   5 秒で強制終了される(11/12 15:51:59 の 0x8BADF00D「Failed to terminate gracefully」)。
///   中の状態(下の private var)は aq の上でだけ触る。外へのコールバック(onError など)は main へ戻して呼ぶ。
final class ConverseAudioIO: @unchecked Sendable {
    enum Failure: Error { case noInput }

    /// 音声の重い呼び出しをすべて載せる直列キュー(main をふさがない)
    private let aq = DispatchQueue(label: "converse-audio", qos: .userInitiated)
    /// 試験用: 設定すると、開始・停止の本体(AVAudioSession / AVAudioEngine)の代わりにこれを aq の上で呼ぶ
    /// (遅い・失敗する音声セッションを、CI の音声サーバーに触れずに再現する)。本番では nil
    var testStartBody: (() throws -> Void)?

    /// PCM16LE mono 16kHz のチャンク(tap スレッドから呼ばれる)
    var onMicChunk: ((Data) -> Void)?
    /// 致命的なエラー(main スレッドから呼ばれる)。本人に伝える文を渡す(会話は止まる)
    var onError: ((String) -> Void)?
    /// 会話は続けるが本人に知らせたいこと(main スレッド)
    var onNotice: ((String) -> Void)?
    /// 診断行(2 秒ごと)に足す文字列(リンクの送信数など)
    var extraDiag: (() -> String)?

    private(set) var running = false { didSet { ConverseAudioIO.active = running } }
    /// 講義録音(TsukaimaMic)と同時に走らせない目印
    nonisolated(unsafe) static var active = false

    private var engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let destFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: ConverseConfig.sampleRate,
                                        channels: 1, interleaved: true)!
    private var observers: [NSObjectProtocol] = []
    private var playQueue: [(id: String, url: URL)] = []
    private var playing = false
    /// 再生が終わったら呼ぶ(main スレッド)。id は再生し終えた audio id。
    var onPlaybackFinished: ((String) -> Void)?

    init() {
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        observers = [
            // queue: nil = 通知を出したスレッドでそのまま受け、必要な値だけ取り出して aq へ渡す(main を通さない)
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: nil) { [weak self] n in
                guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                let began = type == .began
                self?.aq.async { self?.interrupted(began: began) }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: nil) { [weak self] n in
                let raw = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 999
                self?.aq.async { self?.ensureOnQueue(trigger: "routeChange(\(raw):\(AudioDiag.reasonName(raw)))") }
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: nil) { [weak self] _ in
                self?.aq.async {
                    guard let self else { return }
                    self.resetEngine()
                    self.restart(trigger: "mediaReset")
                }
            },
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] n in
                let from = (n.object as? AVAudioEngine).map { ObjectIdentifier($0) }
                self?.aq.async {
                    guard let self, let from, from == ObjectIdentifier(self.engine) else { return }
                    self.restart(trigger: "configChange")
                }
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                // 画面を消したままの手ぶら利用が本来の使い方。background modes の audio があるので止めずに動かし続ける。
                self?.aq.async {
                    guard let self, self.running else { return }
                    AudioDiag.log("audio scene background (keep running) eng=\(self.engine.isRunning)")
                }
            },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.aq.async {
                    guard let self, self.running else { return }
                    AudioDiag.log("audio scene active eng=\(self.engine.isRunning)")
                    self.ensureOnQueue(trigger: "foreground")
                }
            },
        ]
    }

    /// player を外してから engine を作り直す(古い engine にノードを残さない)。
    private func resetEngine() {
        player.stop()
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        engine = AVAudioEngine()
        inputTouched = false
        vpRate = nil
    }

    /// 本体マイク: allowBluetooth を付けない = BT は A2DP(出力のみ)のまま HFP に切り替わらない。
    /// ヘッドセット: 従来どおり allowBluetooth 付き(イヤホンのマイクを使う。経路は HFP に切り替わる)。
    private var baseOptions: AVAudioSession.CategoryOptions {
        switch micChoice {
        case .builtIn: [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
        case .headset: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
        }
    }
    private var micChoice = ConverseMicMode.Choice.builtIn
    private var useVP = true
    private var sessionMode: AVAudioSession.Mode { useVP ? .voiceChat : .default }
    private var tap: ConverseTapStats?
    private let tapLock = NSLock()
    private var diagTimer: DispatchSourceTimer?
    private var recoveryAttempts = 0
    private var recovering = false
    private var silentNoticed = false
    private var inInterruption = false
    private var restartCap = ConverseRestartCap()
    private var debounceItem: DispatchWorkItem?
    private var lastDiagCallbacks = 0
    private var ducking = false
    /// false = 再生専用(ブラインド画面用)。入力ノードに一切触れず、マイクの許可も求めない。
    private var microphone = true
    /// 入力ノード(Voice Processing)を触った engine かどうか。再生専用で始め直すときは engine を作り直す。
    private var inputTouched = false
    /// Voice Processing を有効にしたときのセッションのサンプルレート(engine を作り直したら nil)。同じなら再有効化しない。
    private var vpRate: Double?
    /// restart の歯止め(aq の上でだけ触る)
    private var damperState = ConverseRestartDamper()
    /// 歯止めの状態は鍵でも守る(aq の外から読まれても壊れないように)
    private let damperLock = NSLock()
    private func withRestartCap<T>(_ f: (inout ConverseRestartCap) -> T) -> T {
        damperLock.lock()
        defer { damperLock.unlock() }
        return f(&restartCap)
    }
    private func withDamper<T>(_ f: (inout ConverseRestartDamper) -> T) -> T {
        damperLock.lock()
        defer { damperLock.unlock() }
        return f(&damperState)
    }

    /// 読み上げ中だけ他のアプリ(音楽など)の音量を下げる。終わったら戻す。
    private func setDucking(_ on: Bool) {
        guard ducking != on else { return }
        ducking = on
        let s = AVAudioSession.sharedInstance()
        if microphone {
            let opts = on ? baseOptions.union(.duckOthers) : baseOptions
            try? AudioDiag.setCategory("converse.duck", s, .playAndRecord, mode: sessionMode, options: opts)
        } else {
            try? AudioDiag.setCategory("converse.duck", s, .playback, mode: .default, options: Self.playbackOptions(ducking: on))
        }
        try? AudioDiag.setActive("converse.duck", s, true)
    }

    private static func playbackOptions(ducking: Bool) -> AVAudioSession.CategoryOptions {
        ducking ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
    }

    /// microphone=false は再生専用(ブラインド画面)。入力ノードに触れず、マイクの許可も求めない。
    /// すぐ戻る。実際の開始は aq で行い、終わったら completion を main で呼ぶ(失敗なら Error、成功なら nil)。
    func start(microphone: Bool = true, completion: @escaping @Sendable (Error?) -> Void) {
        aq.async { [self] in
            let result: Error?
            do {
                if let body = testStartBody { try body() } else { try startOnQueue(microphone: microphone) }
                result = nil
            } catch { result = error }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func startOnQueue(microphone: Bool) throws {
        dispatchPrecondition(condition: .onQueue(aq))
        let s = AVAudioSession.sharedInstance()
        self.microphone = microphone
        if microphone {
            let route = s.currentRoute
            let hfp = route.outputs.contains { $0.portType == .bluetoothHFP }
            let bt = route.outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) }
            micChoice = ConverseMicMode.current.resolve(hfpOutputActive: hfp)
            useVP = ConverseAudioPolicy.useVoiceProcessing(choice: micChoice, bluetoothOutput: bt)
            recoveryAttempts = 0
            recovering = false
            silentNoticed = false
            inInterruption = false
            withRestartCap { $0.reset() }
            AudioDiag.log("audio start micMode=\(ConverseMicMode.current.rawValue) choice=\(micChoice) vp=\(useVP) btOut=\(bt) hfpOut=\(hfp) route=\(AudioDiag.ports(route.inputs))>\(AudioDiag.ports(route.outputs))")
            // mixWithOthers: 会話モード中も音楽を止めない。読み上げ中だけ duckOthers で音楽を下げる(9/30 本人)
            try AudioDiag.setCategory("converse.start", s, .playAndRecord, mode: sessionMode, options: baseOptions)
        } else {
            if inputTouched { resetEngine() }
            try AudioDiag.setCategory("converse.start", s, .playback, mode: .default, options: Self.playbackOptions(ducking: false))
        }
        try AudioDiag.setActive("converse.start", s, true)
        running = true
        do { try launch() } catch {
            running = false
            if !microphone {
                try? AudioDiag.setActive("converse.startFail", AVAudioSession.sharedInstance(), false, options: .notifyOthersOnDeactivation)
            }
            throw error
        }
    }

    /// 再生専用から会話モード(マイクあり)へ。再生中の読み上げは restart と同じ経路で続ける。
    /// すぐ戻る。終わったら completion を main で呼ぶ(失敗なら Error)。
    func upgradeToMicrophone(completion: @escaping @Sendable (Error?) -> Void) {
        aq.async { [self] in
            let result: Error?
            do { try upgradeOnQueue(); result = nil } catch { result = error }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func upgradeOnQueue() throws {
        guard running, !microphone else { return }
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute
        micChoice = ConverseMicMode.current.resolve(hfpOutputActive: route.outputs.contains { $0.portType == .bluetoothHFP })
        useVP = ConverseAudioPolicy.useVoiceProcessing(choice: micChoice, bluetoothOutput: route.outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) })
        recoveryAttempts = 0
        let opts = ducking ? baseOptions.union(.duckOthers) : baseOptions
        try AudioDiag.setCategory("converse.upgrade", s, .playAndRecord, mode: sessionMode, options: opts)
        try AudioDiag.setActive("converse.upgrade", s, true)
        microphone = true
        do {
            try launch()
            pumpPlayback()
        } catch {
            // 失敗したら再生専用へ戻して、読み上げの経路は保つ
            microphone = false
            try? AudioDiag.setCategory("converse.upgradeFail", s, .playback, mode: .default, options: Self.playbackOptions(ducking: ducking))
            try? AudioDiag.setActive("converse.upgradeFail", s, true)
            if inputTouched { resetEngine() }
            try? launch()
            throw error
        }
    }

    /// すぐ戻る(止める処理は aq で順番に行う。直後の start はこの後に走る)。
    func stop() {
        aq.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        running = false
        if testStartBody != nil { return }  // 試験では音声に触れない
        stopDiagTimer()
        debounceItem?.cancel()
        debounceItem = nil
        // 開始が失敗した直後の stop では入力ノードに一度も触れていないことがある(触ると入力を作りに行く)
        if microphone, inputTouched { engine.inputNode.removeTap(onBus: 0) }
        player.stop()
        engine.stop()
        playQueue.removeAll()
        playing = false
        ducking = false
        withDamper { $0.cancel() }
        try? AudioDiag.setActive("converse.stop", AVAudioSession.sharedInstance(), false, options: .notifyOthersOnDeactivation)
    }

    /// 録音中なのにエンジンが止まっていたら再開(前面復帰・経路変更時)
    func ensure(trigger: String = "ensure") {
        aq.async { [self] in ensureOnQueue(trigger: trigger) }
    }

    private func ensureOnQueue(trigger: String) {
        if running && !engine.isRunning { restart(trigger: trigger) }
    }

    /// サーバーから届いた wav 1本を再生キューへ。届いた順に再生し、1本終わるごとに onPlaybackFinished を(main で)呼ぶ。
    func enqueuePlayback(id: String, fileURL: URL) {
        aq.async { [self] in
            playQueue.append((id, fileURL))
            pumpPlayback()
        }
    }

    /// 外へのコールバックは main で呼ぶ
    private func onMain(_ f: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: f)
    }

    private func finished(_ id: String) {
        onMain { [weak self] in self?.onPlaybackFinished?(id) }
    }

    private func pumpPlayback() {
        guard running, !playing, let next = playQueue.first else {
            if running, !playing, playQueue.isEmpty { setDucking(false) }
            return
        }
        playing = true
        setDucking(true)
        guard let file = try? AVAudioFile(forReading: next.url) else {
            // 読めない wav はスキップして次へ(サーバー側に played を返し、詰まらせない)
            playQueue.removeFirst()
            playing = false
            finished(next.id)
            pumpPlayback()
            return
        }
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.aq.async {
                guard let self else { return }
                if !self.playQueue.isEmpty { self.playQueue.removeFirst() }
                self.playing = false
                try? FileManager.default.removeItem(at: next.url)
                self.finished(next.id)
                self.pumpPlayback()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func launchPlaybackOnly() throws {
        engine.stop()
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
        }
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func launch() throws {
        guard microphone else { try launchPlaybackOnly(); return }
        inputTouched = true
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        // 入力側で Voice Processing を有効化すると出力側(このあと繋ぐ player)にも自動で効く
        // すでに有効で、セッションのサンプルレートも変わっていなければ呼び直さない(揺れている間の再有効化を避ける)
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        if !useVP {
            if input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(false) }
            vpRate = nil
            AudioDiag.log("audio launch vp=off sr=\(Int(sessionRate))")
        } else if input.isVoiceProcessingEnabled, let kept = vpRate, kept == sessionRate {
            AudioDiag.log("audio launch vp=keep sr=\(Int(sessionRate))")
        } else {
            try input.setVoiceProcessingEnabled(true)
            vpRate = sessionRate
            if #available(iOS 17.0, *) {
                // Voice Processing は既定で他の音をかなり下げる。常時は最小にして、読み上げ中だけ duckOthers で下げる
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            AudioDiag.log("audio launch vp=set sr=\(Int(sessionRate))")
        }
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
        }
        // format: nil で mixer 側のフォーマットに合わせる(player 側は scheduleFile が自動で変換する)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { throw Failure.noInput }
        AudioDiag.log("audio launch inSR=\(Int(inFmt.sampleRate)) ch=\(inFmt.channelCount) fmt=\(inFmt.commonFormat.rawValue) vp=\(input.isVoiceProcessingEnabled)")
        let now = ProcessInfo.processInfo.systemUptime
        tapLock.lock()
        tap = ConverseTapStats(launchedAt: now)
        tapLock.unlock()
        lastDiagCallbacks = 0
        let state = TapConvState()
        // format: nil = ノードの今のフォーマットのまま受ける。経路が変わっても tap の形がずれて黙る/落ちることがない。
        // 変換器は届いた最初の buffer の実際の形から作る(HFP 8kHz / 本体 48kHz など、起動時に読んだ値を信用しない)。
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            self?.convert(buf, state)
        }
        engine.prepare()
        try engine.start()
        player.play()
        startDiagTimer()
    }

    // MARK: 診断・見張り

    private func startDiagTimer() {
        guard diagTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: aq)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.diagTick() }
        diagTimer = t
        t.resume()
    }

    private func stopDiagTimer() {
        diagTimer?.cancel()
        diagTimer = nil
    }

    /// 2 秒ごと: tap の呼び出し数・音量・リンクの送信数を 1 行出し、無音/停止が続いていたら立て直す。
    private func diagTick() {
        guard running, microphone else { return }
        let now = ProcessInfo.processInfo.systemUptime
        tapLock.lock()
        guard var st = tap else { tapLock.unlock(); return }
        let drained = st.drain()
        let verdict = ConverseTapJudge.judge(st, now: now)
        let cb = st.callbacks
        tap = st
        tapLock.unlock()
        let s = AVAudioSession.sharedInstance()
        let extra = extraDiag?() ?? ""
        AudioDiag.log("audio tap cb=\(cb)(+\(cb - lastDiagCallbacks)) frames=\(drained.frames) rms=\(String(format: "%.4f", drained.rms)) peak=\(String(format: "%.3f", drained.peak)) verdict=\(verdict) eng=\(engine.isRunning) vp=\(useVP) sr=\(Int(s.sampleRate)) in=\(AudioDiag.ports(s.currentRoute.inputs)) out=\(AudioDiag.ports(s.currentRoute.outputs)) \(extra)")
        lastDiagCallbacks = cb
        if verdict == .healthy, cb > 0 { recoveryAttempts = 0 }
        guard debounceItem == nil, !recovering, !inInterruption else { return }
        switch verdict {
        case .noCallbacks, .stalled, .allZero: recover(why: "\(verdict)")
        case .waiting, .healthy: break
        }
    }

    /// 無音・停止の立て直し(段階つき。ConverseRecovery)。
    private func recover(why: String) {
        recoveryAttempts += 1
        let step = ConverseRecovery.step(attempt: recoveryAttempts, choice: micChoice)
        AudioDiag.log("audio recover why=\(why) attempt=\(recoveryAttempts) step=\(step)")
        switch step {
        case .rebuildEngine:
            rebuild(src: "recover1")
        case .rebuildWithoutVP:
            useVP = false
            rebuild(src: "recover2")
        case .fallbackToBuiltIn:
            micChoice = .builtIn
            useVP = false
            rebuild(src: "recover3")
            notice("イヤホンのマイクから音が来ないので、本体のマイクに切り替えました。")
        case .giveUp where why == "allZero":
            // 無音のままの部屋かもしれない(VP が 0 を返すことがある)。止めず、一度だけ知らせる
            guard !silentNoticed else { return }
            silentNoticed = true
            notice("マイクの音が入っていないようです。聞こえない場合は、設定の会話のマイクを変えてみてください。")
        case .giveUp:
            giveUp("マイクから音が入ってきません。会話モードを止めました。設定の会話のマイクを変えてみてください。")
        }
    }

    private func notice(_ say: String) {
        onMain { [weak self] in self?.onNotice?(say) }
    }

    /// 設定を変えた・立て直しのとき: カテゴリを入れ直して engine を新品にし、tap を付け直す(aq の上で呼ぶ)。
    private func rebuild(src: String) {
        guard running, microphone else { return }
        recovering = true
        defer { recovering = false }
        let s = AVAudioSession.sharedInstance()
        let opts = ducking ? baseOptions.union(.duckOthers) : baseOptions
        do {
            try AudioDiag.setCategory("converse.\(src)", s, .playAndRecord, mode: sessionMode, options: opts)
            try AudioDiag.setActive("converse.\(src)", s, true)
            resetEngine()
            try launch()
            pumpPlayback()
        } catch {
            AudioDiag.log("audio rebuild fail src=\(src) err=\((error as NSError).domain)#\((error as NSError).code)")
            aq.asyncAfter(deadline: .now() + 2) { [weak self] in self?.restartNow(retry: 1, trigger: "retry") }
        }
    }

    /// 設定画面でマイクを切り替えたとき(会話中)。次の起動を待たずに入れ替える。
    func reconfigureMic() {
        aq.async { [self] in reconfigureMicOnQueue() }
    }

    private func reconfigureMicOnQueue() {
        guard running, microphone else { return }
        let s = AVAudioSession.sharedInstance()
        let hfp = s.currentRoute.outputs.contains { $0.portType == .bluetoothHFP }
        let bt = s.currentRoute.outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) }
        micChoice = ConverseMicMode.current.resolve(hfpOutputActive: hfp)
        useVP = ConverseAudioPolicy.useVoiceProcessing(choice: micChoice, bluetoothOutput: bt)
        recoveryAttempts = 0
        rebuild(src: "settings")
    }

    /// 立て直せない: 会話を止めて理由を本人に伝える(黙ってループしない)。
    private func giveUp(_ say: String) {
        guard running else { return }
        running = false
        AudioDiag.log("audio giveUp: \(say)")
        stopDiagTimer()
        onMain { [weak self] in self?.onError?(say) }
    }

    private func interrupted(began: Bool) {
        AudioDiag.log("audio interruption type=\(began ? "began" : "ended")")
        if began { inInterruption = true; return }
        inInterruption = false
        recoveryAttempts = 0
        // 通話などで再生中に割り込まれた分は取り戻せないので、詰まらせないために「再生済み」扱いにして進める
        if playing, let cur = playQueue.first {
            playQueue.removeFirst()
            playing = false
            try? FileManager.default.removeItem(at: cur.url)
            finished(cur.id)
        }
        restart(trigger: "interruption")
    }

    /// 再起動の入口(構成変更・経路変更・割り込み・リトライのどれもここを通る)。
    /// 直近 10 秒に 4 回以上なら揺れているとみなして、合流させつつ遅らせる(ConverseRestartDamper)。
    private func restart(retry: Int = 0, trigger: String = "?") {
        guard running else { return }
        // 経路変更・構成変更は連続して届く(A2DP→HFP で 1 秒に 2〜3 回)。静まるまで 0.5 秒待ち、1 回の再起動にまとめる。
        // 再起動の最中に別の再起動を重ねない(11/6: routeChange と configChange が 1 秒差で engine を 2 度作り直していた)
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.debounceItem = nil
            let now = ProcessInfo.processInfo.systemUptime
            if !self.withRestartCap({ $0.allow(now: now) }) {
                AudioDiag.log("audio restart capped trig=\(trigger)")
                self.giveUp("音声が何度も切り替わって安定しません。会話モードを止めました。")
                return
            }
            self.restartNow(retry: retry, trigger: trigger)
        }
        debounceItem = item
        aq.asyncAfter(deadline: .now() + ConverseAudioPolicy.routeSettle, execute: item)
    }

    private func restartNow(retry: Int = 0, trigger: String = "?") {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let (decision, n, g) = withDamper { d -> (ConverseRestartDamper.Decision, Int, Int) in
            let dec = d.request(now: now)
            return (dec, d.recentCount, d.generation)
        }
        switch decision {
        case .immediate:
            performRestart(retry: retry, trigger: trigger)
        case .merged:
            AudioDiag.log("audio restart merged trig=\(trigger) n=\(n)")
        case .delay(let wait):
            AudioDiag.log("audio restart damped n=\(n) wait=\(wait) trig=\(trigger)")
            aq.asyncAfter(deadline: .now() + wait) { [weak self] in
                // 待っている間に停止された・講義録音が握った場合は捨てる
                guard let self, self.withDamper({ $0.fire(generation: g) }) else { return }
                guard self.running, !TsukaimaMic.active else { return }
                // 待っている間に start/upgrade/リトライがエンジンを起こしていたら、止めて起こし直さない
                if self.engine.isRunning, trigger.hasPrefix("configChange") || trigger.hasPrefix("routeChange") {
                    AudioDiag.log("audio restart skip running trig=\(trigger)")
                    return
                }
                self.performRestart(retry: retry, trigger: trigger + "+damped")
            }
        }
    }

    private func performRestart(retry: Int, trigger: String) {
        guard running else { return }
        let s = AVAudioSession.sharedInstance()
        AudioDiag.log("audio restart trig=\(trigger) retry=\(retry)/30 run=\(engine.isRunning) mic=\(microphone) n10s=\(withDamper { $0.recentCount }) sr=\(Int(s.sampleRate))")
        do {
            try AudioDiag.setActive("converse.restart", s, true)
            try launch()
            pumpPlayback()
        } catch {
            AudioDiag.log("audio restart fail retry=\(retry) err=\((error as NSError).domain)#\((error as NSError).code)")
            if retry < 30 {
                aq.asyncAfter(deadline: .now() + 2) { [weak self] in self?.restartNow(retry: retry + 1, trigger: "retry") }
            } else {
                giveUp("会話モードの音声を再開できません。会話モードを止めました。")
            }
        }
    }

    /// tap スレッド専用の状態(変換器と端数の持ち越し)
    private final class TapConvState {
        var conv: AVAudioConverter?
        var fmt: AVAudioFormat?
        var carry: [Int16] = []
    }

    // tap スレッドから呼ばれる。buffer の実際の形から変換器を(必要なら作り直して)使う。
    private func convert(_ buf: AVAudioPCMBuffer, _ st: TapConvState) {
        recordTapStats(buf)
        if st.conv == nil || st.fmt != buf.format {
            st.conv = AVAudioConverter(from: buf.format, to: destFmt)
            st.fmt = buf.format
            st.carry.removeAll()
            AudioDiag.log("audio tap format sr=\(Int(buf.format.sampleRate)) ch=\(buf.format.channelCount) conv=\(st.conv != nil)")
        }
        guard let conv = st.conv else { return }
        let ratio = destFmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: destFmt, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let fresh = UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))
        st.carry.append(contentsOf: fresh)
        var ready: [[Int16]] = []
        while st.carry.count >= ConverseConfig.chunkSamples {
            ready.append(Array(st.carry.prefix(ConverseConfig.chunkSamples)))
            st.carry.removeFirst(ConverseConfig.chunkSamples)
        }
        for chunk in ready {
            onMicChunk?(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
        }
    }

    private func recordTapStats(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        var sumSq = 0.0
        var peak: Float = 0
        if let f = buf.floatChannelData, n > 0 {
            let p = f[0]
            for i in 0..<n { let v = p[i]; sumSq += Double(v * v); peak = max(peak, abs(v)) }
        } else if let h = buf.int16ChannelData, n > 0 {
            let p = h[0]
            for i in 0..<n { let v = Float(p[i]) / 32768; sumSq += Double(v * v); peak = max(peak, abs(v)) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        tapLock.lock()
        tap?.add(frames: n, sumSquares: sumSq, peak: peak, now: now)
        tapLock.unlock()
    }
}
