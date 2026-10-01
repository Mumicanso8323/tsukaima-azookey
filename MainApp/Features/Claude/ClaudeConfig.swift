import Foundation

/// Claude タブ(docs/converse-protocol.md 2章)のエンドポイント。
enum ClaudeConfig {
    static var wsURL: URL { TsukaimaEndpoint.webSocketURL("/ws/claude") }
    static var uploadURL: URL { TsukaimaEndpoint.url("/api/claude/upload") }
    static var projectsURL: URL { TsukaimaEndpoint.url("/api/claude/projects") }
    static var sessionsURL: URL { TsukaimaEndpoint.url("/api/claude/sessions") }
    static var stateURL: URL { TsukaimaEndpoint.url("/api/claude/state") }
    /// 短い音声 1 本の文字起こし(PCM16LE 16kHz mono の生バイト列 → {"text"})。Claude タブの音声入力用
    static var sttOnceURL: URL { TsukaimaEndpoint.url("/api/stt/once?rate=16000&lang=ja") }

    /// UI テスト用: サーバーなしで台本どおりのイベントを流す(ClaudeMockDriver)。起動引数 `--claude-mock`
    static var isMock: Bool { ProcessInfo.processInfo.arguments.contains("--claude-mock") }

    /// 候補として出すスラッシュコマンド(`{"type":"keys"}` で画面にそのまま打つ)
    static let slashCommands = ["/compact", "/context", "/usage", "/model", "/effort", "/clear", "/resume", "/cost"]
    /// 固定のモデル一覧(bin/claude-converse の /model が受け付ける slug)。表示は modelLabel(_:)。
    static let models = ["claude-sonnet-5", "claude-opus-5-5", "claude-fable-5", "claude-haiku-4-5"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func modelLabel(_ slug: String?) -> String {
        switch slug {
        case "claude-sonnet-5": return "Sonnet 5"
        case "claude-opus-5-5": return "Opus 5.5"
        case "claude-fable-5": return "Fable 5"
        case "claude-haiku-4-5": return "Haiku 4.5"
        case let other?: return other
        case nil: return "モデル"
        }
    }
}
