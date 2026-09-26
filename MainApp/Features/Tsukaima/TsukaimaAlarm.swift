import AVFoundation
import AudioToolbox
import MediaPlayer
import SwiftUI
import UserNotifications

/// 有線イヤホンを挿したまま寝ても起きられる目覚まし。main スレッド専用。
/// - セット中は無音を再生して背景でも生き続ける(他アプリの ASMR とは混ぜて邪魔しない)
/// - 時刻になったら他アプリの音を止め、出力を本体スピーカーに強制し、音量を最大にして
///   フルスケールの矩形波と振動を鳴らし続ける
/// - 止めるには計算問題。止めた後も 5 分・10 分後に「起きてる？」を出し、放置なら鳴り直す
/// - アプリが殺されたときの保険に、通常の通知も 1 分おきに積んでおく
/// - `answer(_:)` が正解を返す以外の経路(通知を開く・アプリがアクティブになる・シーン遷移・
///   通知デリゲート・音声割り込み・プロセスの再起動)では絶対に鳴りを止めない。
///   再起動時に何をすべきかの判定は `TsukaimaAlarmLogic`(Logic/、単体テスト付き)に切り出してある。
final class TsukaimaAlarm: NSObject, ObservableObject {
    enum Phase: String { case off, armed, ringing, checking }

    private static let phaseKey = "alarm.phase"
    private static let fireAtKey = "alarm.fireAt"
    private static let checkDeadlineKey = "alarm.checkDeadline"
    private static let checksLeftKey = "alarm.checksLeft"

    @Published private(set) var phase = Phase.off {
        didSet {
            TsukaimaAlarm.armedFlag = phase != .off
            UserDefaults.standard.set(phase.rawValue, forKey: TsukaimaAlarm.phaseKey)
        }
    }
    static var armedFlag = false
    @Published private(set) var fireAt: Date?
    @Published private(set) var question = (a: 0, b: 0)
    @Published private(set) var checkDeadline: Date? {
        didSet {
            if let checkDeadline {
                UserDefaults.standard.set(checkDeadline, forKey: TsukaimaAlarm.checkDeadlineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: TsukaimaAlarm.checkDeadlineKey)
            }
        }
    }
    @Published var suggestion: String?

    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var loud = false            // 矩形波を出すか(false の間は無音)
    private var phaseAcc = 0.0
    private var tick: DispatchSourceTimer?
    private var checksLeft = 0 { didSet { UserDefaults.standard.set(checksLeft, forKey: TsukaimaAlarm.checksLeftKey) } }
    private let volume = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        observers = [
            // 他アプリ(ASMR など)に割り込まれても、終わったら張り直す
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
                guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                TsukaimaLog.add("interruption \(type == .began ? "began" : "ended")")
                if type == .ended { self?.resume() }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] _ in
                TsukaimaLog.add("route \(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue))")
                guard let self, self.loud else { return }
                self.forceSpeaker()   // 鳴っている最中にイヤホンが抜き差しされてもスピーカーに戻す
            },
            nc.addObserver(forName: TsukaimaMic.stopped, object: nil, queue: .main) { [weak self] _ in
                TsukaimaLog.add("mic stopped -> reassert")
                self?.quietSession()
            },
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                TsukaimaLog.add("engine config change")
                self?.resume()
            },
        ]
        UNUserNotificationCenter.current().delegate = self
        TsukaimaLog.add("launch")
        restore()
    }

    /// プロセスが(OS に殺されて、あるいはユーザーがスワイプで落として)再起動したときに呼ぶ。
    /// 「答えていない」状態だったなら、経過時間に関わらず今すぐ鳴らし直す。
    /// 判定そのものは `TsukaimaAlarmLogic.decide` (Logic/、単体テスト付き) に切り出してあり、
    /// ここでは結果に従って副作用を実行するだけ。
    private func restore() {
        let last = PersistedAlarmPhase(rawValue: UserDefaults.standard.string(forKey: TsukaimaAlarm.phaseKey) ?? "") ?? .off
        let fireAtStored = UserDefaults.standard.object(forKey: TsukaimaAlarm.fireAtKey) as? Date
        let deadlineStored = UserDefaults.standard.object(forKey: TsukaimaAlarm.checkDeadlineKey) as? Date
        let action = AlarmRestoreLogic.decide(phase: last, fireAt: fireAtStored, checkDeadline: deadlineStored, now: .now)
        TsukaimaLog.add("restore last=\(last.rawValue) fireAt=\(fireAtStored?.formatted(date: .omitted, time: .standard) ?? "-") action=\(action)")
        switch action {
        case .doNothing:
            UserDefaults.standard.removeObject(forKey: TsukaimaAlarm.fireAtKey)
            UserDefaults.standard.removeObject(forKey: TsukaimaAlarm.phaseKey)
            UserDefaults.standard.removeObject(forKey: TsukaimaAlarm.checkDeadlineKey)
            UserDefaults.standard.removeObject(forKey: TsukaimaAlarm.checksLeftKey)
        case .rearm(let t):
            arm(at: t)  // まだ鳴っていなかった armed の続き。通常どおりセットし直す
        case .ringNow:
            // 見逃さず今すぐ鳴らす。armed から直接ここに来た場合は二度寝チェック分を確保し直す
            fireAt = fireAtStored
            checksLeft = last == .armed ? 2 : UserDefaults.standard.integer(forKey: TsukaimaAlarm.checksLeftKey)
            ring()
            startTick()  // 新しいプロセスなので tick はまだ動いていない(振動・音量戻し・鳴り直しに必要)
        case .resumeChecking(let deadline):
            fireAt = fireAtStored
            checksLeft = UserDefaults.standard.integer(forKey: TsukaimaAlarm.checksLeftKey)
            enterChecking(deadline: deadline, needsSessionRestart: true)
            startTick()  // 締切超過を監視して鳴り直すのに必要
        }
    }

    /// 画面外に置いた音量スライダー(システム音量をアプリから動かす唯一の手段)
    var volumeView: some View { VolumeHost(view: volume).frame(width: 1, height: 1).opacity(0.01) }

    func arm(at date: Date) {
        // 時・分だけを使う(ピッカーの Date には秒や古い日付が残っていることがある)。
        // 過ぎてから 1 分以内なら今日のまま = すぐ鳴る。それより前なら明日。
        let hm = Calendar.current.dateComponents([.hour, .minute], from: date)
        var t = Calendar.current.date(bySettingHour: hm.hour!, minute: hm.minute!, second: 0, of: .now)!
        if t < Date.now.addingTimeInterval(-60) { t = Calendar.current.date(byAdding: .day, value: 1, to: t)! }
        TsukaimaLog.add("arm \(t.formatted(date: .abbreviated, time: .standard))")
        fireAt = t
        UserDefaults.standard.set(t, forKey: TsukaimaAlarm.fireAtKey)
        UserDefaults.standard.set(t, forKey: "alarm.last")
        checksLeft = 0
        loud = false
        phase = .armed
        quietSession()
        scheduleBackups(t)
        TsukaimaBackup.schedule(t.addingTimeInterval(60))  // 1 分後に OS の目覚まし(AlarmKit)も鳴らす
        startTick()
    }

    /// 唯一の「意図的に止める」経路。正解を答えた末に自分で呼ぶ(nextCheck 経由)か、
    /// armed 中にユーザーが「解除」を明示的に押した場合だけ。他の経路からは絶対に呼ばない。
    func disarm() {
        TsukaimaLog.add("disarm")
        TsukaimaBackup.cancel()
        stopAll()
        phase = .off
        fireAt = nil
        checkDeadline = nil
        checksLeft = 0
        UserDefaults.standard.removeObject(forKey: TsukaimaAlarm.fireAtKey)
        UserDefaults.standard.removeObject(forKey: TsukaimaAlarm.phaseKey)
        UserDefaults.standard.removeObject(forKey: TsukaimaAlarm.checkDeadlineKey)
        UserDefaults.standard.removeObject(forKey: TsukaimaAlarm.checksLeftKey)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// 計算問題の答え合わせ。正解なら止めて、二度寝チェックへ
    func answer(_ n: Int) -> Bool {
        guard n == question.a + question.b else { newQuestion(); return false }
        TsukaimaLog.add("answered")
        TsukaimaBackup.cancel()
        loud = false
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        nextCheck()
        return true
    }

    /// 「起きてる」ボタン
    func awake() {
        guard phase == .checking else { return }
        nextCheck()
    }

    // MARK: - 内部

    private func nextCheck() {
        if checksLeft == 0 { disarm(); return }
        checksLeft -= 1
        enterChecking(deadline: Date.now.addingTimeInterval(5 * 60))
    }

    /// 二度寝チェック待機へ入る。通常フローと、プロセス再起動からの復元(`restore()`)の両方から使う。
    /// - Parameter needsSessionRestart: 復元直後でエンジンがまだ動いていない場合は true にして張り直す
    private func enterChecking(deadline: Date, needsSessionRestart: Bool = false) {
        phase = .checking
        checkDeadline = deadline
        if needsSessionRestart {
            // 無音再生を新規プロセスで張り直す(通常フローでは ring() 由来のエンジンが既に動いている)
            quietSession()
        } else {
            // 無音再生に戻して生き続ける(背景に回っても期限で鳴り直せるように)
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        }
        scheduleBackups(deadline.addingTimeInterval(60))
        TsukaimaBackup.schedule(deadline.addingTimeInterval(60))
    }

    /// 待機中の音声セッション: 他アプリと混ぜて無音を流す。録音中は録音のセッションをそのまま使う
    private func quietSession() {
        guard phase == .armed || phase == .checking else { return }
        do {
            if !TsukaimaMic.active {
                try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            }
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
        } catch { TsukaimaLog.add("quiet session error \(error)") }
    }

    private func ring() {
        TsukaimaLog.add("RING (phase=\(phase))")
        if phase == .armed { checksLeft = 2 }  // 最初の鳴動のあとは 5 分・10 分後に確認
        phase = .ringing
        newQuestion()
        loud = true
        let s = AVAudioSession.sharedInstance()
        do {
            // mixWithOthers を外す = ASMR など他アプリの再生を止める(録音中なら録音は続く)
            try s.setCategory(.playAndRecord, mode: .default, options: TsukaimaMic.active ? [.defaultToSpeaker] : [])
            try s.setActive(true)
        } catch {}
        forceSpeaker()
        resume()
    }

    private func forceSpeaker() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        maxVolume()
    }

    private func maxVolume() {
        guard let slider = volume.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = 1.0
        slider.sendActions(for: .valueChanged)
    }

    private func newQuestion() {
        question = (Int.random(in: 23...89), Int.random(in: 23...89))
    }

    private func startTick() {
        tick?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        tick = t
    }

    private func onTick() {
        let now = Date.now
        if Int(now.timeIntervalSince1970) % 60 == 0 {
            UserDefaults.standard.set(now, forKey: "alarm.lastTick")  // 背景で生きていたかの証拠
        }
        switch phase {
        case .armed:
            if let f = fireAt, Date.now >= f { ring() }
        case .ringing:
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            if AVAudioSession.sharedInstance().outputVolume < 0.99 { maxVolume() }  // 下げられたら戻す
            if !engine.isRunning { resume() }
        case .checking:
            if let d = checkDeadline, Date.now >= d { ring() }
        case .off:
            break
        }
    }

    private func startEngine() throws {
        if node == nil {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let n = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl -> OSStatus in
                guard let self else { return noErr }
                let buf = UnsafeMutableAudioBufferListPointer(abl)
                // 耳障りな 2 音の交互(0.25 秒ごと)。フルスケールの矩形波 = 出せる最大の音圧
                for i in 0..<Int(frames) {
                    var v: Float = 0
                    if self.loud {
                        let t = self.phaseAcc
                        let hz = Int(t / 44100 * 4) % 2 == 0 ? 2900.0 : 3500.0
                        v = sin(2 * .pi * hz * t / 44100) >= 0 ? 1.0 : -1.0
                    }
                    self.phaseAcc += 1
                    for b in buf { b.mData?.assumingMemoryBound(to: Float.self)[i] = v }
                }
                return noErr
            }
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: fmt)
            engine.mainMixerNode.outputVolume = 1
            node = n
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func resume() {
        guard phase != .off else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if loud { forceSpeaker() }
        try? startEngine()
    }

    private func stopAll() {
        loud = false
        tick?.cancel(); tick = nil
        engine.stop()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// アプリが OS に殺されたときの保険: 1 分おきに 15 回、通常の通知音を積む
    private func scheduleBackups(_ from: Date) {
        let c = UNUserNotificationCenter.current()
        c.removeAllPendingNotificationRequests()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            TsukaimaLog.add("notif auth \(ok)")
            guard ok else { return }
            for i in 0..<15 {
                let content = UNMutableNotificationContent()
                content.title = "起きて！"
                content.body = "使い魔キットを開いて目覚ましを止めてください"
                content.sound = UNNotificationSound(named: UNNotificationSoundName("loud.wav"))
                let d = from.addingTimeInterval(Double(i * 60) + 30)
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
                let req = UNNotificationRequest(identifier: "alarm-\(i)", content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
                c.add(req)
            }
        }
    }
}

/// 通知は「保険で鳴らす・押されたことを記録する」だけ。ここで止めたり `disarm()`/`stopAll()` を
/// 呼んだりしない — それをやると「通知を開くと目覚ましが止まる」バグそのものになる。
extension TsukaimaAlarm: UNUserNotificationCenterDelegate {
    /// アプリがフォアグラウンドでも保険の通知(音・バナー)をそのまま出す。
    /// これを実装しないと iOS は前面表示中の通知を黙って握りつぶす。
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// 通知をタップして開いた瞬間。ここでは何も止めない。答え合わせ画面へ出すかどうかは
    /// scenePhase の変化(App.swift)と `phase` の現在値だけで決まる。
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        TsukaimaLog.add("notification tapped id=\(response.notification.request.identifier) phase=\(phase.rawValue) (not stopping)")
        completionHandler()
    }
}

private struct VolumeHost: UIViewRepresentable {
    let view: MPVolumeView
    func makeUIView(context: Context) -> MPVolumeView { view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
