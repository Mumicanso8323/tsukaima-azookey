import AVFoundation
import SwiftUI

/// 画面の状態と、TsukaimaMic → TsukaimaUplink の配線。main スレッド専用。
/// 画面の状態と main スレッド専用の設計を維持しつつ、DispatchQueue.main.async 等へ self を
/// 送るクロージャの Swift 6 送信検査は @unchecked Sendable で明示的に免除する。
final class TsukaimaRecorderEngine: ObservableObject, @unchecked Sendable {
    enum Phase { case idle, recording, finishing }
    struct Line: Identifiable { let id = UUID(); let text: String }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var course: String?
    @Published private(set) var endAt: Date?
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

    func foreground() {
        if phase == .recording, !mock { mic.ensure() }
    }

    private func begin(_ course: String?) {
        guard phase == .idle else { return }
        error = nil
        lines = []
        self.course = course
        endAt = nil
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
    }

    private func serverStarted(_ st: TsukaimaUplink.Start) {
        if let c = st.course { course = c }
        endAt = st.end
        cancelAutoStop()
        // 終了時刻の1分後に自動停止。音声セッションで起きているので背景でも発火する。
        guard phase == .recording, let end = st.end else { return }
        let wait = end.addingTimeInterval(60).timeIntervalSinceNow
        guard wait > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: .now() + wait)
        t.setEventHandler { [weak self] in self?.stop() }
        t.resume()
        autoStop = t
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
    }

    private func cancelAutoStop() {
        autoStop?.cancel()
        autoStop = nil
    }
}
