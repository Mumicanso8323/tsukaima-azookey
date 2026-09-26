import AppIntents

/// App Intents から投げる簡易エラー(Shortcuts にそのまま表示される)
struct TsukaimaIntentError: Error, CustomLocalizedStringResourceConvertible {
    let text: String
    init(_ text: String) { self.text = text }
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: text) }
}
