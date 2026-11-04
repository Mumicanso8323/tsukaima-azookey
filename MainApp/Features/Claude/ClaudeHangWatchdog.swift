import Darwin
import Foundation

/// UI テスト専用(ClaudeConfig.isMock のときだけ動かす。本番では動かない): メインスレッドが数秒止まったら、
/// 止まっている最中のメインスレッドの呼び出し順(スタック)を一時ディレクトリに書き出す。
/// XCUITest の「main thread busy」「Timed out while evaluating UI query」が、アプリのどこで止まっているかを知るための調査用。
/// 仕組み: 見張りのスレッドが 1 秒ごとにメインスレッドの心拍を見て、3 秒止まっていたら SIGUSR2 を送る。
/// シグナルの処理はメインスレッド上で走るので、そこで backtrace() を取る。
enum ClaudeHangWatchdog {
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var mainThread: pthread_t = pthread_self()
    nonisolated(unsafe) private static var heartbeat: UInt64 = mach_absolute_time()
    nonisolated(unsafe) private static var captured: Int32 = 0
    nonisolated(unsafe) private static var dumps = 0
    private static let capacity: Int32 = 160
    nonisolated(unsafe) private static let buffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 160)

    @MainActor static func start() {
        guard !started else { return }
        started = true
        mainThread = pthread_self()
        heartbeat = mach_absolute_time()
        signal(SIGUSR2) { _ in
            ClaudeHangWatchdog.captured = backtrace(ClaudeHangWatchdog.buffer, ClaudeHangWatchdog.capacity)
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            ClaudeHangWatchdog.heartbeat = mach_absolute_time()
        }
        RunLoop.main.add(timer, forMode: .common)
        let thread = Thread {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            var lastDumpBeat: UInt64 = 0
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                let beat = heartbeat
                let now = mach_absolute_time()
                let stalledSeconds = Double((now &- beat) &* UInt64(info.numer) / UInt64(info.denom)) / 1e9
                // 同じ停止では 1 回だけ書く(2 秒ごとに最大 3 回まで同じ停止を書き足す)
                if stalledSeconds > 3, beat != lastDumpBeat || stalledSeconds.truncatingRemainder(dividingBy: 10) < 1 {
                    if dumps < 12 {
                        lastDumpBeat = beat
                        captured = 0
                        pthread_kill(mainThread, SIGUSR2)
                        Thread.sleep(forTimeInterval: 0.3)
                        write(stalledSeconds: stalledSeconds)
                    }
                }
            }
        }
        thread.name = "ClaudeHangWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func write(stalledSeconds: Double) {
        let n = captured
        guard n > 0, let symbols = backtrace_symbols(buffer, n) else { return }
        dumps += 1
        var text = "HANG stalled=\(String(format: "%.1f", stalledSeconds))s frames=\(n)\n"
        for i in 0..<Int(n) {
            if let c = symbols[i] { text += String(cString: c) + "\n" }
        }
        free(symbols)
        let path = NSTemporaryDirectory() + "hang-\(getpid())-\(dumps).txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
