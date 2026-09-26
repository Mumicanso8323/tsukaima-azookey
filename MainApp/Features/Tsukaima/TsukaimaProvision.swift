import Foundation

/// 署名の有効期限をサーバへ知らせる(失効前に通知してもらうため)。失敗は無視。
enum TsukaimaProvision {
    static func report() {
        guard let expires = expiration() else { return }
        var req = URLRequest(url: TsukaimaConfig.expiryURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "app": "recorder",
            "expires": ISO8601DateFormatter().string(from: expires),
        ])
        URLSession.shared.dataTask(with: req).resume()
    }

    /// embedded.mobileprovision は PKCS7 で包まれた plist。中の <plist>…</plist> だけ切り出して読む。
    static func expiration() -> Date? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .isoLatin1),
              let head = text.range(of: "<plist"),
              let tail = text.range(of: "</plist>", range: head.upperBound..<text.endIndex),
              let xml = text[head.lowerBound..<tail.upperBound].data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: xml, options: 0, format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }
}
