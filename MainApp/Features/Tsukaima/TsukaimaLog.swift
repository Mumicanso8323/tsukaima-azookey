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

    static func upload() {
        let lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !lines.isEmpty else { return }
        var req = URLRequest(url: TsukaimaConfig.logURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["app": "alarm", "lines": lines])
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                DispatchQueue.main.async {
                    let now = UserDefaults.standard.stringArray(forKey: key) ?? []
                    UserDefaults.standard.set(Array(now.dropFirst(lines.count)), forKey: key)
                }
            }
        }.resume()
    }
}
