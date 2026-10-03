import Foundation

/// hub への JSON / multipart POST。TsukaimaRecorder 本体(App Intents)・TsukaimaShare(共有拡張)の両方から使う。
/// api.yusukedoi.com 宛てのときだけ端末の合鍵(Bearer)を付ける(TsukaimaEndpoint.authorize)。Tailscale 宛てはヘッダ不要。
enum TsukaimaNet {
    struct HTTPError: Error, CustomStringConvertible {
        let status: Int
        var description: String { "hub からの応答が失敗しました (HTTP \(status))" }
    }

    @discardableResult
    static func postJSON(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var req = TsukaimaEndpoint.request(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// フォームフィールド(`fields`)+ 1 ファイル(`fileField`)の multipart/form-data を送る
    static func postMultipart(_ url: URL, fields: [String: String], fileField: String,
                               filename: String, mime: String, data: Data) async throws -> [String: Any] {
        let boundary = "TsukaimaBoundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        for (k, v) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n")
            append(v)
            append("\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        var req = TsukaimaEndpoint.request(url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (respData, resp) = try await URLSession.shared.data(for: req)
        try check(resp, respData)
        return (try? JSONSerialization.jsonObject(with: respData) as? [String: Any]) ?? [:]
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = obj["detail"] as? String {
                throw NSError(domain: "hub", code: status, userInfo: [NSLocalizedDescriptionKey: detail])
            }
            throw HTTPError(status: status)
        }
    }
}
