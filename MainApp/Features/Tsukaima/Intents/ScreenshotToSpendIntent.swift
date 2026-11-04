import AppIntents
import UIKit
import UniformTypeIdentifiers
import Vision

/// スクリーンショット(PayPay 等の支払い完了画面)を端末上で OCR し、
/// bot/web.py の POST /api/spend/ocr ({"text","source"?,"ts"?}) へ送る
struct ScreenshotToSpendIntent: AppIntent {
    static let title: LocalizedStringResource = "スクショを出費に"
    static let description = IntentDescription("支払い完了画面のスクリーンショットを OCR して出費に記録します。")
    static let openAppWhenRun = false

    // supportedContentTypes: 付きの初期化子は iOS 18+ 限定(デプロイ対象は 17)なので使わない。
    // 画像以外が来た場合は perform() 内の UIImage デコードでエラーにする。
    @Parameter(title: "画像") var image: IntentFile

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uiImage = UIImage(data: image.data), let cg = uiImage.cgImage else {
            throw TsukaimaIntentError("画像を読み込めませんでした")
        }
        let text = try Self.recognizeText(cg)
        guard !text.isEmpty else {
            throw TsukaimaIntentError("文字を読み取れませんでした")
        }
        let json: [String: Any]
        do {
            json = try await TsukaimaNet.postJSON(TsukaimaHub.ocrURL, ["text": text, "source": "screenshot"])
        } catch {
            throw TsukaimaIntentError("送信に失敗しました: \(error.localizedDescription)")
        }
        let notice = (json["notice"] as? String) ?? "記録しました"
        return .result(dialog: "\(notice)")
    }

    /// VNRecognizeTextRequest は同期 API。AppIntent の perform は既にバックグラウンドで動くのでそのまま呼ぶ。
    private static func recognizeText(_ image: CGImage) throws -> String {
        var lines: [String] = []
        let request = VNRecognizeTextRequest { req, _ in
            lines = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return lines.joined(separator: "\n")
    }
}
