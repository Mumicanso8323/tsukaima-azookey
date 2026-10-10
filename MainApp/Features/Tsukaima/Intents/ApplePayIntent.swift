import AppIntents

/// bot/web.py の POST /api/spend/applepay ({"merchant","amount","card","transaction","ts"?}) に合わせる。
/// 「取引」に Wallet の取引オートメーション変数をまるごと渡せば、merchant/amount を個別に渡さなくても記録できる
struct RecordApplePayIntent: AppIntent {
    static let title: LocalizedStringResource = "Apple Pay を記録"
    static let description = IntentDescription("Wallet の取引オートメーションから、支払いを使い魔に記録します。「取引」に Wallet の取引変数をそのまま渡せます。")
    static let openAppWhenRun = false

    @Parameter(title: "支払先") var merchant: String?
    @Parameter(title: "金額") var amount: Double?
    @Parameter(title: "カード") var card: String?
    @Parameter(title: "取引") var transaction: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Apple Pay の支払いを記録 (\(\.$merchant) ¥\(\.$amount) \(\.$transaction))")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var body: [String: Any] = [:]
        if let merchant, !merchant.trimmingCharacters(in: .whitespaces).isEmpty { body["merchant"] = merchant }
        if let amount { body["amount"] = amount }
        if let card, !card.trimmingCharacters(in: .whitespaces).isEmpty { body["card"] = card }
        if let transaction, !transaction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["transaction"] = transaction }
        guard !body.isEmpty else {
            throw TsukaimaIntentError("支払先・金額・取引のいずれかを指定してください")
        }
        let json: [String: Any]
        do {
            json = try await TsukaimaNet.postJSON(TsukaimaHub.applePayURL, body)
        } catch {
            throw TsukaimaIntentError("送信に失敗しました: \(error.localizedDescription)")
        }
        let notice = (json["notice"] as? String) ?? "記録しました"
        return .result(dialog: "\(notice)")
    }
}
