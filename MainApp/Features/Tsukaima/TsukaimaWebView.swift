import SwiftUI
import WebKit

/// 使い魔の Web 画面(voice-ab.html 等)をアプリ内で開く。外のブラウザだと device_token が無いので
/// forbidden になる(bot/web.py の guard ミドルウェア)。ここでは WKWebView の Cookie ストアに
/// 合鍵(TsukaimaDeviceToken)を device_token として積んでから読み込む(サーバーは Authorization: Bearer
/// と Cookie: device_token のどちらでも受け付ける。TsukaimaEndpoint.authorize と同じ合鍵)。
struct TsukaimaWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard !context.coordinator.loaded else { return }
        context.coordinator.loaded = true
        loadWithCookie(webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded = false
    }

    private func loadWithCookie(_ webView: WKWebView) {
        guard let token = TsukaimaDeviceToken.read(), let host = url.host else {
            webView.load(URLRequest(url: url))
            return
        }
        guard let cookie = HTTPCookie(properties: [
            .domain: host,
            .path: "/",
            .name: "device_token",
            .value: token,
            .secure: true,
        ]) else {
            webView.load(URLRequest(url: url))
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            webView.load(URLRequest(url: url))
        }
    }
}

/// 「使い魔」設定タブから開く、Web 画面の一覧(サーバーの静的公開許可リストと合わせる。bot/web.py の allowed)。
struct TsukaimaWebPagesView: View {
    private struct Page: Identifiable {
        let id = UUID()
        let title: String
        let file: String
    }

    private let pages: [Page] = [
        Page(title: "声の聴き比べ(voice-ab)", file: "voice-ab.html"),
        Page(title: "目覚ましの設定", file: "alarm-setup.html"),
        Page(title: "アイコン一覧", file: "icons.html"),
        Page(title: "TODO", file: "todo.html"),
        Page(title: "VR リーダー", file: "vr-reader.html"),
        Page(title: "部屋の状態", file: "rooms.html"),
        Page(title: "BOOTH 3D カタログ", file: "booth3d.html"),
    ]

    var body: some View {
        List(pages) { page in
            NavigationLink(page.title) {
                TsukaimaWebView(url: TsukaimaEndpoint.url("/\(page.file)"))
                    .navigationTitle(page.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationTitle("使い魔の Web 画面")
    }
}
