import AppIntents

/// bot/presence.py の EVENTS と一致させること(home_arrive / home_leave / charger_night)
enum PresenceEvent: String, AppEnum {
    case homeLeave = "home_leave"
    case homeArrive = "home_arrive"
    case chargerNight = "charger_night"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "在不在イベント"
    static let caseDisplayRepresentations: [PresenceEvent: DisplayRepresentation] = [
        .homeLeave: "外出",
        .homeArrive: "帰宅",
        .chargerNight: "就寝(充電開始)",
    ]
}

struct RecordPresenceIntent: AppIntent {
    static let title: LocalizedStringResource = "在不在を記録"
    static let description = IntentDescription("外出・帰宅・就寝(充電開始)を使い魔に伝えます。オートメーションから使います。")
    static let openAppWhenRun = false

    @Parameter(title: "イベント") var event: PresenceEvent

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$event) を記録")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            _ = try await TsukaimaNet.postJSON(TsukaimaHub.presenceURL, ["event": event.rawValue])
        } catch {
            throw TsukaimaIntentError("送信に失敗しました: \(error.localizedDescription)")
        }
        return .result(dialog: "記録しました")
    }
}
