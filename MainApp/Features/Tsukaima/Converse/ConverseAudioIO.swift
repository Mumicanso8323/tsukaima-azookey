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
    /// 致命的なエラー(main スレッドから呼ばれる)
    var onError: ((String) -> Void)?

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
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
                self?.interrupted(n)
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] _ in
                self?.ensure()
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.engine = AVAudioEngine()
                self.restart()
            },
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
                guard let self, (n.object as? AVAudioEngine) === self.engine else { return }
                self.restart()
            },
        ]
    }

    private static let baseOptions: AVAudioSession.CategoryOptions =
        [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
    private var ducking = false

    /// 読み上げ中だけ他のアプリ(音楽など)の音量を下げる。終わったら戻す。
    private func setDucking(_ on: Bool) {
        guard ducking != on else { return }
        ducking = on
        let s = AVAudioSession.sharedInstance()
        let opts = on ? Self.baseOptions.union(.duckOthers) : Self.baseOptions
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: opts)
        try? s.setActive(true)
    }

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        // .voiceChat: 会話向け(エコー消去・AGC 込み)。allowBluetooth でイヤホン/ヘッドセットのマイクも使える。
        // mixWithOthers: 会話モード中も音楽を止めない。読み上げ中だけ duckOthers で音楽を下げる(9/30 本人)
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: Self.baseOptions)
        try s.setActive(true)
        running = true
        do { try launch() } catch { running = false; throw error }
    }

    func stop() {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        playQueue.removeAll()
        playing = false
        ducking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 録音中なのにエンジンが止まっていたら再開(前面復帰・経路変更時)
    func ensure() {
        if running && !engine.isRunning { restart() }
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
        setDucking(true)
        guard let file = try? AVAudioFile(forReading: next.url) else {
            // 読めない wav はスキップして次へ(サーバー側に played を返し、詰まらせない)
            playQueue.removeFirst()
            playing = false
            let id = next.id
            DispatchQueue.main.async { [weak self] in self?.onPlaybackFinished?(id) }
            pumpPlayback()
            return
        }
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.playQueue.isEmpty { self.playQueue.removeFirst() }
                self.playing = false
                try? FileManager.default.removeItem(at: next.url)
                self.onPlaybackFinished?(next.id)
                self.pumpPlayback()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func launch() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        // 入力側で Voice Processing を有効化すると出力側(このあと繋ぐ player)にも自動で効く
        try input.setVoiceProcessingEnabled(true)
        if #available(iOS 17.0, *) {
            // Voice Processing は既定で他の音をかなり下げる。常時は最小にして、読み上げ中だけ duckOthers で下げる
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
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
        if playing, let cur = playQueue.first {
            playQueue.removeFirst()
            playing = false
            try? FileManager.default.removeItem(at: cur.url)
            onPlaybackFinished?(cur.id)
        }
        restart()
    }

    private func restart(retry: Int = 0) {
        guard running else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try launch()
            pumpPlayback()
        } catch {
            if retry < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.restart(retry: retry + 1) }
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
