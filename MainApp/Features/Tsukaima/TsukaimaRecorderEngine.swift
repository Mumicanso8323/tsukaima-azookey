import ActivityKit
import AVFoundation
import SwiftUI
import UserNotifications

/// 自動停止の方針(純粋関数。テストできる)。止める判定はサーバー(時間割)が持ち、アプリは従うだけ。
/// サーバーに繋がらず auto_stop が届かない場合に備えた保険だけをアプリ側に持つ。
enum TsukaimaAutoStopPolicy {
    /// サーバーが決めた停止時刻のあと、これだけ待っても止まらなければアプリ側で止める保険
    static let fallbackMargin: TimeInterval = 90

    /// stopAt が無い(時間割に紐付かない手動の録音)ときは nil = 保険のタイマーも置かない = 止めない
    static func fallbackDeadline(stopAt: Date?) -> Date? {
        stopAt.map { $0.addingTimeInterval(fallbackMargin) }
    }
}

/// 画面の状態と、TsukaimaMic → TsukaimaUplink の配線。main スレッド専用。
/// 画面の状態と main スレッド専用の設計を維持しつつ、DispatchQueue.main.async 等へ self を
/// 送るクロージャの Swift 6 送信検査は @unchecked Sendable で明示的に免除する。
final class TsukaimaRecorderEngine: ObservableObject, @unchecked Sendable {
    /// 画面(AppTabView)と App Intent(授業の自動録音)が同じ録音を触るための共有インスタンス
    static let shared = TsukaimaRecorderEngine()

    enum Phase { case idle, recording, finishing }
    struct Line: Identifiable { let id = UUID(); let text: String }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var course: String?
    @Published private(set) var endAt: Date?
    @Published private(set) var stopAt: Date?       // 自動停止の予定時刻(時間割に紐付かない録音は nil)
    @Published private(set) var stopWarning = false // 停止1分前の予告中
    @Published private(set) var stoppedNote: String?
    @Published private(set) var lines: [Line] = []
    @Published private(set) var link = TsukaimaUplink.State.idle
    @Published private(set) var pending = 0
    @Published private(set) var error: String?

    private let mic = TsukaimaMic()
    private let up = TsukaimaUplink()
    private var autoStop: DispatchSourceTimer?

    /// UI テスト専用(起動引数 `--rec-mock`): マイク・送信・権限確認なしで、最初から録音中にする。
    private let mock = ProcessInfo.processInfo.arguments.contains("--rec-mock")

    init() {
        if mock {
            phase = .recording
            startedAt = Date()
            return
        }
        mic.onChunk = { [weak self] in self?.up.push($0) }
        mic.onError = { [weak self] in self?.error = $0 }
        up.onState = { [weak self] s, n in self?.link = s; self?.pending = n }
        up.onStart = { [weak self] in self?.serverStarted($0) }
        up.onText = { [weak self] in self?.append($0) }
        up.onDone = { [weak self] in self?.finished() }
        up.onWarn = { [weak self] in self?.warned($0) }
        up.onAutoStop = { [weak self] in self?.autoStopped($0) }
        up.onSchedule = { [weak self] in self?.rescheduled($0) }
    }

    func toggle() {
        switch phase {
        case .idle: start(course: nil)
        case .recording: stop()
        case .finishing: up.abort(); finished()  // 送れない分は諦める
        }
    }

    func start(course: String?) {
        guard phase == .idle else { return }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async {
                if ok { self.begin(course) } else { self.error = "マイクが許可されていません(設定 > 使い魔キット)" }
            }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        if mock { phase = .idle; startedAt = nil; return }
        cancelAutoStop()
        mic.stop()
        up.finish()
        phase = .finishing
    }

    /// 「延長」: 自動停止を15分先へ。サーバーが新しい停止時刻を返す
    func extendStop() {
        guard phase == .recording, !mock else { return }
        stopWarning = false
        up.extend()
    }

    func foreground() {
        if phase == .recording, !mock { mic.ensure() }
        if phase == .idle, !mock { TsukaimaRecLive.end() }  // アプリが落ちて取り残された表示を消す
    }

    private func begin(_ course: String?) {
        guard phase == .idle else { return }
        error = nil
        lines = []
        self.course = course
        endAt = nil
        stopAt = nil
        stopWarning = false
        stoppedNote = nil
        up.begin(course: course)
        do {
            try mic.start()
        } catch {
            up.abort()
            self.error = "録音を開始できません: \(error.localizedDescription)"
            return
        }
        phase = .recording
        startedAt = Date()
        TsukaimaRecLive.start(course: course ?? "授業の録音", startedAt: startedAt ?? Date())
    }

    private func serverStarted(_ st: TsukaimaUplink.Start) {
        if let c = st.course { course = c }
        endAt = st.end
        rescheduled(st.stopAt)
    }

    /// サーバーが決めた停止時刻を反映し、保険のタイマーを置き直す(延長のたびにここへ来る)
    private func rescheduled(_ at: Date?) {
        cancelAutoStop()
        stopAt = at
        stopWarning = false
        guard phase == .recording, let deadline = TsukaimaAutoStopPolicy.fallbackDeadline(stopAt: at) else { return }
        let wait = deadline.timeIntervalSinceNow
        guard wait > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: .now() + wait)
        t.setEventHandler { [weak self] in
            self?.stoppedNote = "予定の時刻を過ぎたので止めました"
            self?.stop()
        }
        t.resume()
        autoStop = t
    }

    private func warned(_ at: Date?) {
        guard phase == .recording else { return }
        stopWarning = true
        if let at { stopAt = at }
        let c = UNMutableNotificationContent()
        c.title = "録音をあと1分で止めます"
        c.body = "続けるときはアプリを開いて「延長」を押してください"
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "rec-autostop-warn", content: c, trigger: nil))
    }

    /// 時間割どおりの停止。通常の stop() と同じ道(溜めた音声を送り切ってから終わる)なので録音は失われない
    private func autoStopped(_ reason: String) {
        guard phase == .recording else { return }
        stoppedNote = "授業の終了から10分たったので自動で止めました"
        stop()
    }

    private func append(_ text: String) {
        lines.append(Line(text: text))
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    private func finished() {
        cancelAutoStop()
        if phase == .recording { mic.stop() }
        phase = .idle
        startedAt = nil
        stopAt = nil
        stopWarning = false
        TsukaimaRecLive.end()
    }

    private func cancelAutoStop() {
        autoStop?.cancel()
        autoStop = nil
    }
}

/// 録音中の Live Activity。iOS 18 の AudioRecordingIntent が求める「録音中の表示」を、手動・自動どちらの録音でも出す。
enum TsukaimaRecLive {
    nonisolated(unsafe) private static var current: Activity<TsukaimaRecActivityAttributes>?

    static func start(course: String, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            TsukaimaLog.add("live activity: 許可されていない")
            return
        }
        end()
        let content = ActivityContent(state: TsukaimaRecActivityAttributes.ContentState(startedAt: startedAt, stopAt: nil), staleDate: nil)
        do {
            current = try Activity.request(attributes: TsukaimaRecActivityAttributes(course: course), content: content)
        } catch {
            TsukaimaLog.add("live activity: 開始できない \(error.localizedDescription)")
        }
    }

    static func end() {
        let all = Activity<TsukaimaRecActivityAttributes>.activities
        current = nil
        guard !all.isEmpty else { return }
        Task { for a in all { await a.end(nil, dismissalPolicy: .immediate) } }
    }
}
