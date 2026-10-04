import SwiftUI
import WebKit

/// 使い魔の Web 画面(voice-ab.html 等)をアプリ内で開く。外のブラウザだと device_token が無いので
/// forbidden になる(bot/web.py の guard ミドルウェア)。ここでは WKWebView の Cookie ストアに
/// 合鍵(TsukaimaDeviceToken)を device_token として積んでから読み込む(サーバーは Authorization: Bearer
/// と Cookie: device_token のどちらでも受け付ける。TsukaimaEndpoint.authorize と同じ合鍵)。
struct TsukaimaWebView: UIViewRepresentable {
    let url: URL

    /// UI テスト専用: --web-mock-page のときはネットワークに出ず、ローカルの確認用ページを読む。
    static var isMockPage: Bool { ProcessInfo.processInfo.arguments.contains("--web-mock-page") }

    func makeUIView(context: Context) -> WKWebView {
        // 非永続のストア: 合鍵の Cookie が Safari や端末の永続領域に残らない(この WebView を閉じれば消える)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.accessibilityIdentifier = "web.view"
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard !context.coordinator.loaded else { return }
        context.coordinator.loaded = true
        loadWithCookie(webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = false

        // 外付けキーボードのキーを Web ページの keydown/keyup に届けるため、読み込み後に WebView を第一応答者にする
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = webView.becomeFirstResponder()
        }
    }

    private func load(_ webView: WKWebView) {
        if Self.isMockPage {
            webView.loadHTMLString(Self.mockFixture, baseURL: URL(string: "https://api.yusukedoi.com/"))
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    private func loadWithCookie(_ webView: WKWebView) {
        let mock = Self.isMockPage
        // モックでは本物の Keychain を読まない
        let token = mock ? "MOCKTOKEN" : TsukaimaDeviceToken.read()
        let host = mock ? "api.yusukedoi.com" : url.host
        guard let token, let host else {
            load(webView)
            return
        }
        guard let cookie = HTTPCookie(properties: [
            .domain: host,
            .path: "/",
            .name: "device_token",
            .value: token,
            .secure: true,
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]) else {
            load(webView)
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            load(webView)
        }
    }

    /// --web-mock-page 用: Cookie が HttpOnly で見えないこと・キーの押下集合・スクロール位置を画面に出す
    private static let mockFixture = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{font:16px sans-serif;margin:0}#tall{height:3000px;background:linear-gradient(#fff,#ccc)}</style></head>
    <body>
    <div id="ready">fixture-ready</div>
    <div id="cookie"></div>
    <div id="held"></div>
    <div id="scrolly">0</div>
    <div id="tall"></div>
    <script>
    document.getElementById('cookie').textContent = document.cookie;
    var held = {};
    function show() { document.getElementById('held').textContent = Object.keys(held).sort().join(','); }
    addEventListener('keydown', function(e) { if (e.code === 'Space') e.preventDefault(); held[e.code] = true; show(); }, true);
    addEventListener('keyup', function(e) { if (e.code === 'Space') e.preventDefault(); delete held[e.code]; show(); }, true);
    addEventListener('scroll', function() { document.getElementById('scrolly').textContent = String(Math.round(window.scrollY)); });
    </script></body></html>
    """
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
