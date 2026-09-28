import AVFoundation

/// マイク → 16kHz mono Float32 → 1秒ごとの Data。ディスクには一切書かない。
/// 内部の可変状態は NSLock(サンプル用)と `active` の nonisolated(unsafe) で自前管理しているため、
/// クロージャで self を非隔離コンテキスト(DispatchQueue.main.async 等)へ送る際の
/// Swift 6 の送信検査は @unchecked Sendable で明示的に免除する。
final class TsukaimaMic: @unchecked Sendable {
    enum Failure: Error { case noInput }

    var onChunk: ((Data) -> Void)?   // tap スレッドから呼ばれる
    var onError: ((String) -> Void)? // main
    private(set) var running = false { didSet { TsukaimaMic.active = running } }
    nonisolated(unsafe) static var active = false        // 目覚ましが音声セッションを奪わないための目印
    static let stopped = Notification.Name("MicStopped")

    private var engine = AVAudioEngine()
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TsukaimaConfig.sampleRate,
                                       channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        observers = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
                self?.interrupted(n)
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] _ in
                // 録音中にイヤホンが挿されたら入力がイヤホン側に移るので、本体マイクへ戻す
                if self?.running == true { TsukaimaMic.preferBuiltInMic() }
                self?.ensure()
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.engine = AVAudioEngine()
                self.restart()
            },
            // 入力フォーマットが変わる(イヤホン抜き差し等)とエンジンが止まるので張り直す
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
                guard let self, (n.object as? AVAudioEngine) === self.engine else { return }
                self.restart()
            },
        ]
    }

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        // mixWithOthers: 他アプリが音を鳴らしても割り込まれない。何も再生はしない。
        try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try s.setActive(true)
        TsukaimaMic.preferBuiltInMic()
        running = true
        do { try launch() } catch { running = false; throw error }
    }

    /// イヤホンを挿したままでも本体のマイクで録る(イヤホンのマイクは音質が悪い。本人の希望)。
    /// すでに本体マイクなら何もしない(経路変更通知 → ここ → 経路変更…のループを避ける)
    static func preferBuiltInMic() {
        let s = AVAudioSession.sharedInstance()
        if s.currentRoute.inputs.first?.portType == .builtInMic { return }
        guard let builtin = s.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        try? s.setPreferredInput(builtin)
    }

    /// 今どのマイクで録っているか(録音画面に出す)
    static var inputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "不明"
    }

    func stop() {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let rest = samples; samples = []; lock.unlock()
        if !rest.isEmpty { emit(rest) }
        // 目覚ましがセット中ならセッションは畳まず、目覚まし側に張り直してもらう
        if TsukaimaAlarm.armedFlag {
            NotificationCenter.default.post(name: TsukaimaMic.stopped, object: nil)
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// 録音中なのにエンジンが止まっていたら再開(前面復帰・経路変更時)
    func ensure() {
        if running && !engine.isRunning { restart() }
    }

    private func launch() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0,
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw Failure.noInput }
        conv.downmix = true
        let ratio = outFmt.sampleRate / inFmt.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in
            self?.convert(buf, conv, ratio)
        }
        engine.prepare()
        try engine.start()
    }

    private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        restart() // 通話後は shouldResume の有無に関わらず再開する
    }

    private func restart(retry: Int = 0) {
        guard running else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try launch()
        } catch {
            // 背景からの再開は一時的に拒否されることがあるので少し待って再試行
            if retry < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.restart(retry: retry + 1) }
            } else {
                onError?("マイクを再開できません")
            }
        }
    }

    private func convert(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter, _ ratio: Double) {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        var ready: [[Float]] = []
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        while samples.count >= TsukaimaConfig.chunk {
            ready.append(Array(samples.prefix(TsukaimaConfig.chunk)))
            samples.removeFirst(TsukaimaConfig.chunk)
        }
        lock.unlock()
        ready.forEach(emit)
    }

    // iOS は little-endian なので Float のメモリをそのまま送る
    private func emit(_ s: [Float]) {
        onChunk?(s.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
