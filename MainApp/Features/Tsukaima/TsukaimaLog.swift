import Foundation

/// 目覚ましの動作記録。端末に 300 行まで溜め、前面に来たときに hub へ送る(失敗は無視)。
enum TsukaimaLog {
    private static let key = "alarm.log"
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func add(_ s: String) {
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        lines.append(fmt.string(from: .now) + " " + s)
        UserDefaults.standard.set(Array(lines.suffix(300)), forKey: key)
    }

    /// audio 診断行は別のリング(100 行)に溜める。揺れが続いてもアラームの行を押し出さない。
    private static let audioKey = "alarm.audiolog"
    static let audioCap = 100

    static func addAudio(_ s: String) {
        var lines = UserDefaults.standard.stringArray(forKey: audioKey) ?? []
        lines.append(fmt.string(from: .now) + " " + s)
        UserDefaults.standard.set(Array(lines.suffix(audioCap)), forKey: audioKey)
    }

    /// 2 つのリングを時刻の文字列順に混ぜる(同じ秒は alarm 行 → audio 行の順)。
    static func merged(_ main: [String], _ audio: [String]) -> [String] {
        let all = main.map { (0, $0) } + audio.map { (1, $0) }
        return all.enumerated().sorted { a, b in
            let ka = String(a.element.1.prefix(14)), kb = String(b.element.1.prefix(14))
            if ka != kb { return ka < kb }
            if a.element.0 != b.element.0 { return a.element.0 < b.element.0 }
            return a.offset < b.offset
        }.map { $0.element.1 }
    }

    static func upload() {
        let mainLines = UserDefaults.standard.stringArray(forKey: key) ?? []
        let audioLines = UserDefaults.standard.stringArray(forKey: audioKey) ?? []
        let lines = merged(mainLines, audioLines)
        guard !lines.isEmpty else { return }
        var req = TsukaimaEndpoint.request(TsukaimaConfig.logURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["app": "alarm", "lines": lines])
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                DispatchQueue.main.async {
                    let now = UserDefaults.standard.stringArray(forKey: key) ?? []
                    UserDefaults.standard.set(Array(now.dropFirst(mainLines.count)), forKey: key)
                    let nowAudio = UserDefaults.standard.stringArray(forKey: audioKey) ?? []
                    UserDefaults.standard.set(Array(nowAudio.dropFirst(audioLines.count)), forKey: audioKey)
                }
            }
        }.resume()
    }
}
