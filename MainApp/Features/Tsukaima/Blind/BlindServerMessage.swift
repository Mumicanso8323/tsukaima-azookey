import Foundation

/// `audio` ヘッダ(この直後に wav のバイナリが 1 本続く)。
struct BlindAudioHeader: Equatable, Sendable {
    let id: String
    let kind: String
    let bytes: Int
    let rid: Int?
}

/// /ws/blind でサーバーから届くメッセージ。未知の type・型違い・壊れた JSON は nil(無視)。
enum BlindServerMessage: Equatable, Sendable {
    case ready(proto: Int?, epoch: String?)
    case reply(BlindReply)
    case output(BlindOutputMode)
    case path(ok: Bool, busy: Bool, audioOwner: String, name: String?)
    case held(Int)
    case audio(BlindAudioHeader)
    case beep(BlindBeep)
    case state(blindOn: Bool, mode: String)
    case listener(Bool)
    case configOK(Int)

    static func parse(_ text: String) -> BlindServerMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready(proto: BlindJSON.int(object["proto"]), epoch: object["epoch"] as? String)
        case "reply":
            guard let reply = BlindReply.parse(object) else { return nil }
            return .reply(reply)
        case "output":
            guard let raw = object["mode"] as? String, let mode = BlindOutputMode(rawValue: raw) else { return nil }
            return .output(mode)
        case "path":
            guard let ok = object["ok"] as? Bool, let busy = object["busy"] as? Bool else { return nil }
            return .path(ok: ok, busy: busy, audioOwner: object["audio_owner"] as? String ?? "none",
                         name: object["name"] as? String)
        case "held":
            guard let count = BlindJSON.int(object["count"]) else { return nil }
            return .held(count)
        case "audio":
            guard let id = object["id"] as? String, !id.isEmpty else { return nil }
            return .audio(BlindAudioHeader(id: id,
                                           kind: object["kind"] as? String ?? "speech",
                                           bytes: BlindJSON.int(object["bytes"]) ?? 0,
                                           rid: BlindJSON.int(object["rid"])))
        case "beep":
            guard let name = object["name"] as? String, let beep = BlindBeep(rawValue: name) else { return nil }
            return .beep(beep)
        case "state":
            guard let blindOn = object["blind_on"] as? Bool, let mode = object["mode"] as? String else { return nil }
            return .state(blindOn: blindOn, mode: mode)
        case "listener":
            guard let on = object["on"] as? Bool else { return nil }
            return .listener(on)
        case "config_ok":
            guard let count = BlindJSON.int(object["count"]) else { return nil }
            return .configOK(count)
        default:
            return nil
        }
    }
}

/// hello(proto 2)で宣言する内容。純粋な値なので JSON の中身をテストできる。
struct BlindHelloState: Equatable, Sendable {
    var device: String
    var audio: Bool
    var output: BlindOutputMode
    var route: BlindRoute
    var lastEpoch: String
    var lastRid: Int

    func jsonText() -> String? {
        let object: [String: Any] = [
            "type": "hello",
            "proto": 2,
            "device": device,
            "caps": ["audio": audio, "haptic": true],
            "output": output.rawValue,
            "route": route.rawValue,
            "last": ["epoch": lastEpoch, "rid": lastRid],
        ]
        return BlindJSON.encode(object)
    }
}

extension BlindJSON {
    static func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
