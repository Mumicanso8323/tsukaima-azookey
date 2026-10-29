import AVFoundation

/// 会話モード専用の音声入出力。TsukaimaMic(講義録音・Float32・mode=.measurement)とは別物:
/// - 入力ノードに Voice Processing(エコー消去)を有効化する(AVAudioInputNode.setVoiceProcessingEnabled)。
///   これは入出力が同じ Voice-Processing I/O ユニットを共有するため、入力側で有効にすると出力側にも効く
///   (Apple の仕様どおり)。だから再生も「同じ engine の playerNode」を通す必要がある
///   (別の AVAudioPlayer を使うとエコー消去の対象から外れる)。
/// - 送信フォーマットは converse-protocol.md 記載の PCM16LE・モノラル・16kHz(/ws/record の Float32 とは違う)。
/// - 再生中も録音を止めない(engine は録音・再生を両方持ったまま動き続ける)。
final class ConverseAudioIO: @unchecked Sendable {
    enum Failure: Error { case noInput }

    /// PCM16LE mono 16kHz のチャンク(tap スレッドから呼ばれる)
    var onMicChunk: ((Data) -> Void)?
    /// 致命的なエラー(main スレッドから呼ばれる)。再起動を 30 回試しても起こせなかったとき
    var onError: ((String) -> Void)?
    /// イヤホンなどが外れた(main)。再生は止めて捨ててある。呼び出し側は返事を溜める合図をサーバーへ送る(A5)
    var onRouteLost: (() -> Void)?
    /// イヤホンなどが付いた(main)(A5)
    var onRouteGained: (() -> Void)?
    /// onError のあとの recover() で起こせた(main)(A4)
    var onRecovered: (() -> Void)?

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
    /// 再生中の 1 本の世代。完了ハンドラとウォッチドッグのどちらが先でも 1 回だけ次へ進める(A4・S17)
    private var playToken = 0
    /// 再生が終わったら呼ぶ(main スレッド)。id は再生し終えた audio id。
    var onPlaybackFinished: ((String) -> Void)?

    init() {
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        observers = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
                self?.interrupted(n)
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] n in
                let raw = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 999
                self?.routeChanged(raw)
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.resetEngine()
                self.restart(trigger: "mediaReset")
            },
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
                guard let self, (n.object as? AVAudioEngine) === self.engine else { return }
                self.restart(trigger: "configChange")
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

    private static let baseOptions: AVAudioSession.CategoryOptions =
        [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
    private var ducking = false
    /// false = 再生専用(ブラインド画面用)。入力ノードに一切触れず、マイクの許可も求めない。
    private var microphone = true
    /// 入力ノード(Voice Processing)を触った engine かどうか。再生専用で始め直すときは engine を作り直す。
    private var inputTouched = false
    /// Voice Processing を有効にしたときのセッションのサンプルレート(engine を作り直したら nil)。同じなら再有効化しない。
    private var vpRate: Double?
    /// restart の歯止め(main スレッドでだけ触る)
    private var damperState = ConverseRestartDamper()
    /// stop() は main 以外(ConverseIntents など)からも呼ばれうるので、歯止めの状態は鍵で守る
    private let damperLock = NSLock()
    private func withDamper<T>(_ f: (inout ConverseRestartDamper) -> T) -> T {
        damperLock.lock()
        defer { damperLock.unlock() }
        return f(&damperState)
    }

    /// 読み上げ中だけ他のアプリ(音楽など)の音量を下げる。終わったら戻す。
    /// 端末側の読み上げ(ConverseLocalVoice)の間も呼び出し側がこれで下げる。
    func setDucking(_ on: Bool) {
        guard running, ducking != on else { return }
        ducking = on
        let s = AVAudioSession.sharedInstance()
        if microphone {
            let opts = on ? Self.baseOptions.union(.duckOthers) : Self.baseOptions
            try? AudioDiag.setCategory("converse.duck", s, .playAndRecord, mode: .voiceChat, options: opts)
        } else {
            try? AudioDiag.setCategory("converse.duck", s, .playback, mode: .default, options: Self.playbackOptions(ducking: on))
        }
        try? AudioDiag.setActive("converse.duck", s, true)
    }

    private static func playbackOptions(ducking: Bool) -> AVAudioSession.CategoryOptions {
        ducking ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
    }

    /// microphone=false は再生専用(ブラインド画面)。入力ノードに触れず、マイクの許可も求めない。
    func start(microphone: Bool = true) throws {
        let s = AVAudioSession.sharedInstance()
        self.microphone = microphone
        if microphone {
            // .voiceChat: 会話向け(エコー消去・AGC 込み)。allowBluetooth でイヤホン/ヘッドセットのマイクも使える。
            // mixWithOthers: 会話モード中も音楽を止めない。読み上げ中だけ duckOthers で音楽を下げる(9/30 本人)
            try AudioDiag.setCategory("converse.start", s, .playAndRecord, mode: .voiceChat, options: Self.baseOptions)
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
    func upgradeToMicrophone() throws {
        guard running, !microphone else { return }
        let s = AVAudioSession.sharedInstance()
        let opts = ducking ? Self.baseOptions.union(.duckOthers) : Self.baseOptions
        try AudioDiag.setCategory("converse.upgrade", s, .playAndRecord, mode: .voiceChat, options: opts)
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

    func stop() {
        running = false
        if microphone { engine.inputNode.removeTap(onBus: 0) }
        player.stop()
        engine.stop()
        playQueue.removeAll()
        playing = false
        playToken += 1
        ducking = false
        withDamper { $0.cancel() }
        try? AudioDiag.setActive("converse.stop", AVAudioSession.sharedInstance(), false, options: .notifyOthersOnDeactivation)
    }

    /// 録音中なのにエンジンが止まっていたら再開(前面復帰・経路変更時)
    func ensure(trigger: String = "ensure") {
        if running && !engine.isRunning { restart(trigger: trigger) }
    }

    /// 再起動を諦めた(onError)あとの自動復帰(A4・S16 S18)。リトライ回数を 0 から数え直す。
    func recover() {
        guard running else { return }
        withDamper { $0.cancel() }
        restart(trigger: "recover")
    }

    /// 経路変更(A5・S20)。イヤホンが外れた(oldDeviceUnavailable)ときは、内蔵スピーカーから返事が
    /// 鳴り出す前に再生を止めて捨て(served 扱いで played を返す)、呼び出し側に知らせる。
    private func routeChanged(_ raw: UInt) {
        let kind = ConverseRouteChange.classify(reasonRaw: raw)
        AudioDiag.log("audio route \(raw):\(AudioDiag.reasonName(raw)) kind=\(kind) playing=\(playing) q=\(playQueue.count)")
        switch kind {
        case .deviceLost:
            if running {
                player.pause()
                discardPlayback()
                onRouteLost?()
            }
        case .deviceGained:
            if running { onRouteGained?() }
        case .other:
            break
        }
        ensure(trigger: "routeChange(\(raw):\(AudioDiag.reasonName(raw)))")
    }

    /// 再生待ちを全部捨てて played を返す(サーバーを待たせない)
    private func discardPlayback() {
        let items = playQueue
        playQueue.removeAll()
        playing = false
        playToken += 1
        setDucking(false)
        for it in items {
            try? FileManager.default.removeItem(at: it.url)
            onPlaybackFinished?(it.id)
        }
    }

    /// サーバーから届いた wav 1本を再生キューへ。届いた順に再生し、1本終わるごとに onPlaybackFinished を呼ぶ。
    func enqueuePlayback(id: String, fileURL: URL) {
        playQueue.append((id, fileURL))
        pumpPlayback()
    }

    private func pumpPlayback() {
        guard running, !playing, let next = playQueue.first else {
            if running, !playing, playQueue.isEmpty { setDucking(false) }
            return
        }
        playing = true
        playToken += 1
        let token = playToken
        setDucking(true)
        guard let file = try? AVAudioFile(forReading: next.url) else {
            // 読めない wav はスキップして次へ(サーバー側に played を返し、詰まらせない)
            finishCurrent(token: token, how: "unreadable")
            pumpPlayback()
            return
        }
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.finishCurrent(token: token, how: "done") else { return }
                self.pumpPlayback()
            }
        }
        if !player.isPlaying { player.play() }
        // 完了が来なくても wav の長さ+5 秒で次へ(A4・S17)
        let limit = ConversePlaybackWatchdog.deadline(frames: file.length, sampleRate: file.processingFormat.sampleRate)
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self, self.playing, self.playToken == token else { return }
            AudioDiag.logWithApp("audio play watchdog id=\(next.id) limit=\(Int(limit))s")
            _ = self.finishCurrent(token: token, how: "watchdog")
            self.player.stop()
            if self.engine.isRunning { self.player.play() } else { self.restart(trigger: "playWatchdog") }
            self.pumpPlayback()
        }
    }

    /// 再生中の 1 本を終える。token が今の世代と違えば(すでに別の経路で終えていれば)何もせず false。
    @discardableResult
    private func finishCurrent(token: Int, how: String) -> Bool {
        guard playing, playToken == token, let cur = playQueue.first else { return false }
        playQueue.removeFirst()
        playing = false
        playToken += 1
        try? FileManager.default.removeItem(at: cur.url)
        if how != "done" { AudioDiag.log("audio play finish id=\(cur.id) how=\(how)") }
        onPlaybackFinished?(cur.id)
        return true
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
        if input.isVoiceProcessingEnabled, let kept = vpRate, kept == sessionRate {
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
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0,
              let conv = AVAudioConverter(from: inFmt, to: destFmt) else { throw Failure.noInput }
        let ratio = destFmt.sampleRate / inFmt.sampleRate
        AudioDiag.log("audio launch inSR=\(Int(inFmt.sampleRate)) ch=\(inFmt.channelCount)")
        var carry: [Int16] = []
        let lock = NSLock()
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in
            self?.convert(buf, conv, ratio, &carry, lock)
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        // 通話などで再生中に割り込まれた分は取り戻せないので、詰まらせないために「再生済み」扱いにして進める
        if playing { finishCurrent(token: playToken, how: "interruption") }
        restart(trigger: "interruption")
    }

    /// 再起動の入口(構成変更・経路変更・割り込み・リトライのどれもここを通る)。
    /// 直近 10 秒に 4 回以上なら揺れているとみなして、合流させつつ遅らせる(ConverseRestartDamper)。
    private func restart(retry: Int = 0, trigger: String = "?") {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
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
            if trigger.hasPrefix("recover") { onRecovered?() }
        } catch {
            AudioDiag.log("audio restart fail retry=\(retry) err=\((error as NSError).domain)#\((error as NSError).code)")
            if retry < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.restart(retry: retry + 1, trigger: "retry") }
            } else {
                onError?("会話モードの音声を再開できません")
            }
        }
    }

    // tap スレッドから呼ばれる。carry は端数サンプルの持ち越し(呼び出し元でロック済み)。
    private func convert(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter, _ ratio: Double,
                          _ carry: inout [Int16], _ lock: NSLock) {
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
        lock.lock()
        carry.append(contentsOf: fresh)
        var ready: [[Int16]] = []
        while carry.count >= ConverseConfig.chunkSamples {
            ready.append(Array(carry.prefix(ConverseConfig.chunkSamples)))
            carry.removeFirst(ConverseConfig.chunkSamples)
        }
        lock.unlock()
        for chunk in ready {
            onMicChunk?(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
        }
    }
}
