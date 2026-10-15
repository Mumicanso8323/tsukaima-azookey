import Foundation

/// 画面から hub(portal-bot)を呼ぶ唯一の入口(docs/tsukaima-native-plan.md の API 契約)。
/// - 登録済み: https://api.yusukedoi.com + `Authorization: Bearer <端末の合鍵>`
/// - 未登録:   https://ashwell-hub.taila653da.ts.net(Tailscale 接続中だけ届く。署名・ステップアップ不要)
/// - signed:  X-Tsukaima-Ts / X-Tsukaima-Sig(/api/main/*・/api/inbox など。Face ID なし)
/// - stepup:  Face ID → /api/stepup/native → X-Elevation-Token(5 分キャッシュ。期限切れの 401 は 1 回だけ取り直す)
enum TsukaimaAPIError: LocalizedError {
    case http(Int, String)
    case notPaired
    case stepupCancelled
    case decoding(any Error)
    case transport(any Error)

    var errorDescription: String? {
        switch self {
        case .http(let status, let detail): detail.isEmpty ? "hub からの応答が失敗しました (HTTP \(status))" : detail
        case .notPaired: "hub につながりません。Tailscale につなぐか、使い魔タブの設定でこの端末を登録してください"
        case .stepupCancelled: "本人確認が取り消されました"
        case .decoding: "hub の応答を読み取れませんでした"
        case .transport(let e): "hub につながりません: \(e.localizedDescription)"
        }
    }
}

@MainActor
final class TsukaimaAPI {
    static let shared = TsukaimaAPI()

    private var elevation: (token: String, until: Date)?
    /// Face ID 中のステップアップ。並行して来た要求は同じ 1 本に相乗りさせる
    /// (新しい LAContext の評価は前の評価を取り消すので、並行で走らせると誰も native まで届かない)
    private var stepupInFlight: Task<(token: String, until: Date), Error>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    var isPaired: Bool { TsukaimaDeviceAuth.isPaired }

    // MARK: 契約

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try decode(try await perform("GET", path, query: query, body: nil, contentType: nil, signed: false, stepup: false))
    }

    func getJSON(_ path: String, query: [String: String] = [:]) async throws -> Any {
        try parse(try await perform("GET", path, query: query, body: nil, contentType: nil, signed: false, stepup: false))
    }

    func send<T: Decodable>(_ method: String, _ path: String, json: Any? = nil, signed: Bool = false, stepup: Bool = false) async throws -> T {
        let body = try encodeBody(json)
        return try decode(try await perform(method, path, query: [:], body: body, contentType: body == nil ? nil : "application/json",
                                            signed: signed, stepup: stepup))
    }

    func sendJSON(_ method: String, _ path: String, json: Any? = nil, signed: Bool = false, stepup: Bool = false) async throws -> Any {
        let body = try encodeBody(json)
        return try parse(try await perform(method, path, query: [:], body: body, contentType: body == nil ? nil : "application/json",
                                           signed: signed, stepup: stepup))
    }

    func upload(_ path: String, data: Data, filename: String, mime: String, fields: [String: String] = [:]) async throws -> Any {
        let boundary = "TsukaimaBoundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        let field = Self.fileField(for: path)
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        return try parse(try await perform("POST", path, query: [:], body: body,
                                           contentType: "multipart/form-data; boundary=\(boundary)", signed: false, stepup: false))
    }

    /// 昇格トークンを捨てる(登録解除時など)
    func clearElevation() { elevation = nil }

    // MARK: 本体

    private func perform(_ method: String, _ path: String, query: [String: String], body: Data?, contentType: String?,
                         signed: Bool, stepup: Bool, retried: Bool = false) async throws -> Data {
        let paired = isPaired
        var comps = URLComponents(url: TsukaimaEndpoint.url(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw TsukaimaAPIError.http(400, "URL を組み立てられませんでした") }
        var req = TsukaimaEndpoint.request(url)
        req.httpMethod = method.uppercased()
        req.httpBody = body
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        // Tailscale 経由(未登録)は hub が署名・ステップアップを求めないので付けない
        if paired {
            if stepup {
                req.setValue(try await elevationToken(), forHTTPHeaderField: "X-Elevation-Token")
            }
            if signed {
                do {
                    let headers = try TsukaimaDeviceAuth.signatureHeaders(method: method, path: url.path, body: body ?? Data())
                    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                } catch {
                    throw TsukaimaAPIError.http(401, "端末署名を作れませんでした。設定から登録し直してください")
                }
            }
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch {
            throw paired ? TsukaimaAPIError.transport(error) : TsukaimaAPIError.notPaired
        }
        let (data, resp) = result
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if 200..<300 ~= status { return data }

        // サーバ再起動などで昇格トークンが消えていたら、1 回だけ Face ID から取り直す
        if status == 401, stepup, paired, !retried, Self.errorCode(from: data) == "stepup_required" {
            elevation = nil
            return try await perform(method, path, query: query, body: body, contentType: contentType,
                                     signed: signed, stepup: stepup, retried: true)
        }
        if status == 403, !paired { throw TsukaimaAPIError.notPaired }
        throw TsukaimaAPIError.http(status, Self.detail(from: data))
    }

    private func elevationToken() async throws -> String {
        if let e = elevation, e.until > Date() { return e.token }
        do {
            let task: Task<(token: String, until: Date), Error>
            if let running = stepupInFlight {
                task = running
            } else {
                task = Task { @MainActor in
                    let el = try await TsukaimaDeviceAuth.stepUp()
                    // サーバの有効期限より少し手前で捨てる
                    return (el.token, Date().addingTimeInterval(TimeInterval(max(el.expiresIn - 20, 30))))
                }
                stepupInFlight = task
            }
            defer { if stepupInFlight == task { stepupInFlight = nil } }
            let got = try await task.value
            elevation = got
            return got.token
        } catch TsukaimaDeviceAuth.AuthError.cancelled {
            throw TsukaimaAPIError.stepupCancelled
        } catch TsukaimaDeviceAuth.AuthError.notPaired {
            throw TsukaimaAPIError.notPaired
        } catch TsukaimaDeviceAuth.AuthError.server(let status, let detail) {
            throw TsukaimaAPIError.http(status, detail)
        } catch let e as TsukaimaDeviceAuth.AuthError {
            // 鍵の更新が要る・Tailscale が要るなど、そのまま読める案内を出す
            throw TsukaimaAPIError.http(401, e.localizedDescription)
        } catch let e as TsukaimaDeviceKeys.KeyError {
            throw TsukaimaAPIError.http(401, e.localizedDescription)
        } catch let e as TsukaimaAPIError {
            throw e
        } catch {
            throw TsukaimaAPIError.transport(error)
        }
    }

    // MARK: 補助

    private func encodeBody(_ json: Any?) throws -> Data? {
        guard let json else { return nil }
        if let d = json as? Data { return d }
        if JSONSerialization.isValidJSONObject(json) {
            return try JSONSerialization.data(withJSONObject: json)
        }
        if let e = json as? any Encodable {
            do { return try JSONEncoder().encode(e) } catch { throw TsukaimaAPIError.decoding(error) }
        }
        throw TsukaimaAPIError.http(400, "送る内容を JSON にできませんでした")
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TsukaimaAPIError.decoding(error)
        }
    }

    private func parse(_ data: Data) throws -> Any {
        if data.isEmpty { return [String: Any]() }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw TsukaimaAPIError.decoding(error)
        }
    }

    /// FastAPI の {"detail": "..."} / {"detail": {"error": "..."}} / {"error": "..."} から人向けの文を取り出す
    nonisolated static func detail(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let s = obj["detail"] as? String { return s }
        if let d = obj["detail"] as? [String: Any], let s = d["error"] as? String { return s }
        if let s = obj["error"] as? String { return s }
        return ""
    }

    nonisolated static func errorCode(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let d = obj["detail"] as? [String: Any] { return d["error"] as? String }
        return obj["error"] as? String
    }

    /// multipart のファイル欄の名前(hub 側のフォーム定義に合わせる。既定は "file")
    nonisolated private static func fileField(for path: String) -> String {
        path.hasPrefix("/api/meals") ? "photo" : "file"
    }
}
