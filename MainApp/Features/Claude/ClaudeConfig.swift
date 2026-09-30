import Foundation

/// Claude タブ(docs/converse-protocol.md 2章)のエンドポイント。
enum ClaudeConfig {
    static var wsURL: URL { TsukaimaEndpoint.webSocketURL("/ws/claude") }
    static var uploadURL: URL { TsukaimaEndpoint.url("/api/claude/upload") }
    static var projectsURL: URL { TsukaimaEndpoint.url("/api/claude/projects") }
    static var stateURL: URL { TsukaimaEndpoint.url("/api/claude/state") }

    /// 候補として出すスラッシュコマンド(サーバーには send.text にそのまま渡す)
    static let slashCommands = ["/compact", "/context", "/usage", "/model", "/effort", "/clear", "/resume", "/cost"]
    static let models = ["sonnet", "opus", "haiku"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
}
