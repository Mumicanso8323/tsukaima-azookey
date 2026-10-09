import SwiftUI
import WebKit

/// 使い魔の Web 画面(voice-ab.html 等)をアプリ内で開く。外のブラウザだと device_token が無いので
/// forbidden になる(bot/web.py の guard ミドルウェア)。ここでは WKWebView の Cookie ストアに
/// 合鍵(TsukaimaDeviceToken)を device_token として積んでから読み込む(サーバーは Authorization: Bearer
/// と Cookie: device_token のどちらでも受け付ける。TsukaimaEndpoint.authorize と同じ合鍵)。
struct TsukaimaWebView: UIViewRepresentable {
    let url: URL
    /// UI テスト専用(--web-mock-page): Cookie の属性を読み戻した結果(値は含めない)を渡す
    var onCookieState: (@MainActor (String) -> Void)? = nil

    /// UI テスト専用: --web-mock-page のときはネットワークに出ず、ローカルの確認用ページを読む。
    static var isMockPage: Bool { ProcessInfo.processInfo.arguments.contains("--web-mock-page") }
    /// UI テスト専用(--tap-mock-lang-press, --web-mock-page と併用): 読み込み後に、実機の pressesBegan と同じ処理へ
    /// 英数(Lang2)の押下・離上を流す(UI テストからは本物のハードウェアキーを送れないため)。
    static var isMockLangPress: Bool { isMockPage && ProcessInfo.processInfo.arguments.contains("--tap-mock-lang-press") }

    func makeUIView(context: Context) -> WKWebView {
        // 既定の永続ストア(アプリのサンドボックス内。Safari とは別)。localStorage の設定や投票は残す。
        // 合鍵の Cookie だけは、閉じるとき(dismantleUIView / カバーの onDisappear)に必ず消す。
        let config = WKWebViewConfiguration()
        // 署名つき POST(forge.html・voice-ab.html の投票など)用: ページの signMainRequest を、
        // 端末の Secure Enclave 鍵で署名するネイティブ橋に差し替える(WebCrypto の鍵はサーバに登録されていない)
        config.userContentController.addScriptMessageHandler(TsukaimaSignBridge.shared, contentWorld: .page, name: TsukaimaSignBridge.name)
        config.userContentController.addUserScript(WKUserScript(source: TsukaimaSignBridge.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = LangKeyWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.accessibilityIdentifier = "web.view"
        // Caps Lock (HID 0x39) は練習ページ(tap.html)のときだけ橋が消費してページへ注入する。他のページは従来どおり。
        webView.configureCapsLock(accepts: url.lastPathComponent == "tap.html")
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard !context.coordinator.loaded else { return }
        context.coordinator.loaded = true
        loadWithCookie(webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        (webView as? LangKeyWebView)?.releaseAllLangKeys()
        let store = webView.configuration.websiteDataStore
        Task { @MainActor in removeDeviceCookie(from: store) }
    }

    /// 直列に消すための、直前の削除(再オープンの setCookie は、これの完了を待ってから積む)
    @MainActor private static var pendingRemoval: Task<Void, Never>?

    /// 合鍵の Cookie(device_token)を記憶域から消す。ページを開いている間だけ鍵が残るようにする。
    /// 削除は前の削除の後に 1 本ずつ走り、loadWithCookie の setCookie はこの完了を待つ。
    @MainActor static func removeDeviceCookie(from store: WKWebsiteDataStore = .default()) {
        let prev = pendingRemoval
        pendingRemoval = Task { @MainActor in
            await prev?.value
            let jar = store.httpCookieStore
            for c in await jar.allCookies() where c.name == "device_token" {
                await jar.delete(c)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = false
        private var mockLangPressSent = false

        // 外付けキーボードのキーを Web ページの keydown/keyup に届けるため、読み込み後に WebView を第一応答者にする
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = webView.becomeFirstResponder()
            guard let langView = webView as? LangKeyWebView else { return }
            langView.reevaluateCapsLock()
            // 失敗で止まっていた keydown/keyup があれば、ページの準備ができたここから順に送り直す
            langView.langPageReady()
            if TsukaimaWebView.isMockLangPress, !mockLangPressSent {
                mockLangPressSent = true
                // 実機の pressesBegan / pressesEnded と同じ共通処理(handleLangPress)を通す
                _ = langView.handleLangPress(usage: LangKey.lang2.rawValue, phase: .down)
                _ = langView.handleLangPress(usage: LangKey.lang2.rawValue, phase: .up)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            (webView as? LangKeyWebView)?.reevaluateCapsLock()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            (webView as? LangKeyWebView)?.langPageReady()
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
        let store = webView.configuration.websiteDataStore
        let report = mock ? onCookieState : nil
        Task { @MainActor in
            // 直前に閉じたページの削除が、この setCookie の後に着かないよう、先に待つ
            await Self.pendingRemoval?.value
            await store.httpCookieStore.setCookie(cookie)
            if mock {
                let c = await store.httpCookieStore.allCookies().first { $0.name == "device_token" }
                var state = "none"
                if let c { state = "name=\(c.name);httpOnly=\(c.isHTTPOnly);secure=\(c.isSecure)" }
                report?(state + ";persistent=\(store.isPersistent)")
            }
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
    <div id="langlog"></div>
    <div id="scrolly">0</div>
    <div id="signallow">signallow:pending</div>
    <div id="signdeny">signdeny:pending</div>
    <div id="signiframe">signiframe:pending</div>
    <iframe style="display:none" srcdoc="<script>window.webkit.messageHandlers.tsukaimaSign.postMessage({method:'POST',path:'/api/forge/start',body:''}).then(function(r){parent.document.getElementById('signiframe').textContent='signiframe:'+(r.error||'ok')},function(e){parent.document.getElementById('signiframe').textContent='signiframe:throw'})</script>"></iframe>
    <div id="tall"></div>
    <script>
    async function signMainRequest() { throw new Error('orig'); }
    document.getElementById('cookie').textContent = 'cookie-js:[' + document.cookie + ']';
    var held = {};
    function show() { document.getElementById('held').textContent = Object.keys(held).sort().join(','); }
    addEventListener('keydown', function(e) { if (e.code === 'Space') e.preventDefault(); held[e.code] = true; show(); }, true);
    addEventListener('keyup', function(e) { if (e.code === 'Space') e.preventDefault(); delete held[e.code]; show(); }, true);
    var langlog = [];
    function lang(e) {
      if (e.code !== 'Lang1' && e.code !== 'Lang2') return;
      langlog.push((e.type === 'keydown' ? 'down:' : 'up:') + e.code);
      document.getElementById('langlog').textContent = 'langlog:' + langlog.join(',');
    }
    addEventListener('keydown', lang, true);
    addEventListener('keyup', lang, true);
    function trySign(id, path, body) {
      signMainRequest('POST', path, body).then(
        function () { document.getElementById(id).textContent = id + ':ok'; },
        function (e) { document.getElementById(id).textContent = id + ':' + e.message; });
    }
    setTimeout(function () {
      trySign('signallow', '/api/forge/sessions/ses_abc123/prompt', '{"text":"x"}');
      trySign('signdeny', '/api/main/send', '{"text":"x"}');
    }, 300);
    addEventListener('scroll', function() { document.getElementById('scrolly').textContent = String(Math.round(window.scrollY)); });
    </script></body></html>
    """
}

/// Web ページから端末署名を頼めるかの規則(純粋。単体テストする)。
/// 条件はすべて満たす必要がある: 本ページ(メインフレーム)・信頼する出所(https・公開ホスト・443 を完全一致)・
/// 許可リストにある METHOD+パス・本文が上限以内。何でも署名する口にはしない。
enum TsukaimaSignPolicy {
    static let maxBodyBytes = 64 * 1024
    static let bridgeVersion = 1

    /// 署名してよい (METHOD, パス) の許可リスト。forge の POST 4 本と、署名つきの既存ページ(アイコン選び・声の投票)だけ。
    static func pathAllowed(method: String, path: String) -> Bool {
        guard method == "POST" else { return false }
        switch path {
        case "/api/forge/sessions", "/api/forge/start", "/api/icons/pick", "/api/voice-ab/vote":
            return true
        default:
            break
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // ["", "api", "forge", "sessions", sid, "prompt"|"abort"]
        guard parts.count == 6, parts[0].isEmpty, parts[1] == "api", parts[2] == "forge", parts[3] == "sessions",
              parts[5] == "prompt" || parts[5] == "abort" else { return false }
        let sid = parts[4]
        guard sid.hasPrefix("ses_"), sid.count > 4, sid.count <= 68 else { return false }
        return sid.dropFirst(4).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func originTrusted(scheme: String, host: String, port: Int) -> Bool {
        scheme == "https" && host == TsukaimaEndpoint.publicHost && (port == 0 || port == 443)
    }

    static func allows(isMainFrame: Bool, scheme: String, host: String, port: Int,
                       method: String, path: String, bodyBytes: Int) -> Bool {
        isMainFrame
            && originTrusted(scheme: scheme, host: host, port: port)
            && pathAllowed(method: method, path: path)
            && bodyBytes <= maxBodyBytes
    }
}

/// Web ページの署名要求(tsukaima-sign.js の signMainRequest)を受けて、端末署名を返す橋。
/// 署名の中身(METHOD\nPATH\nTS\nsha256(body))はアプリが自分で組み立てる(TsukaimaDeviceAuth.signatureHeaders)。
/// ページが渡せるのは METHOD・パス・本文だけで、TsukaimaSignPolicy を通らないものは署名しない。
@MainActor final class TsukaimaSignBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = TsukaimaSignBridge()
    static let name = "tsukaimaSign"

    /// UI テスト専用(--web-mock-page): Secure Enclave の無いシミュレーターでも許可経路を最後まで通せるよう、偽の署名を返す
    private static var signer: (String, String, Data) throws -> [String: String] {
        if TsukaimaWebView.isMockPage {
            return { _, _, _ in ["X-Tsukaima-Ts": "0", "X-Tsukaima-Sig": "MOCKSIG"] }
        }
        return { try TsukaimaDeviceAuth.signatureHeaders(method: $0, path: $1, body: $2) }
    }

    /// signMainRequest が定義されているページ(tsukaima-sign.js を読むページ)でだけ差し替える
    static let script = """
    (function () {
      if (typeof window.signMainRequest !== 'function') return;
      window.signMainRequest = async function (method, path, bodyText) {
        var r = await window.webkit.messageHandlers.\(TsukaimaSignBridge.name).postMessage({ method: String(method), path: String(path), body: bodyText || '' });
        if (!r || r.error) throw new Error((r && r.error) || 'sign-failed');
        return { 'x-tsukaima-ts': r.ts, 'x-tsukaima-sig': r.sig };
      };
    })();
    """

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let d = message.body as? [String: Any],
              let method = (d["method"] as? String)?.uppercased(), let path = d["path"] as? String,
              let body = d["body"] as? String else { return (["error": "bad-request"], nil) }
        let o = message.frameInfo.securityOrigin
        guard TsukaimaSignPolicy.allows(isMainFrame: message.frameInfo.isMainFrame,
                                        scheme: o.protocol, host: o.host, port: o.port,
                                        method: method, path: path, bodyBytes: body.utf8.count) else {
            return (["error": "denied"], nil)
        }
        do {
            let h = try Self.signer(method, path, Data(body.utf8))
            return (["ts": h["X-Tsukaima-Ts"] ?? "", "sig": h["X-Tsukaima-Sig"] ?? ""], nil)
        } catch {
            return (["error": "sign-failed"], nil)
        }
    }
}

/// 英数(Lang2 = 0x91)・かな(Lang1 = 0x90)を、アプリ側で受けて Web ページの keydown/keyup として注入する WKWebView。
/// iOS はこの 2 つのキーを IME の切り替えに使い、Web には渡さない。
///
/// - 消費(super に渡さない)するのは、この WebView が第一応答者として画面にある間の Lang1/Lang2 だけ。ほかのキーは必ず super へ渡す。
///   画面から消えれば(インスタンスごと)通常の動作に戻る。グローバルな状態は持たない。
/// - FocusGuard は Claude / HardwareIME の入力欄だけが対象、BlindKeyCapture はブラインド画面だけの第一応答者。
///   この WebView は別の全画面カバーに載り(FocusGuard は modalPresented で待つ)、どちらの対象でもないので取り合わない。
/// - 制限: ページ内の入力欄にフォーカスがあるときは WebKit の内部ビューが先にキーを受ける。Lang キーがそこから
///   こちらへ回るかは実機確認が要る(入力欄・選択・ソフトウェアキーボードの動作には触れない)。
final class LangKeyWebView: WKWebView {
    private var langQueue = LangKeyEventQueue()
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    private var retries = 0

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // 画面から消える: 押したままのキーに keyup を送ってから、アプリの通知の購読を外す
            releaseAllLangKeys()
            if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
            resignObserver = nil
        } else if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseAllLangKeys() }
            }
        }
    }

    deinit {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 共通処理(実機の presses とテストフックの両方がここを通る)

    /// 練習ページでだけ Caps Lock を橋の対象にする(makeUIView で 1 度だけ。押下が空の状態で呼ぶ)
    func configureCapsLock(accepts: Bool) {
        langQueue.setAcceptsCapsLock(accepts)
        pumpLang()
    }

    /// 表示中のページから再評価する(同じ WebView でページが遷移しても追従する)
    func reevaluateCapsLock() {
        configureCapsLock(accepts: url?.lastPathComponent == "tap.html")
    }

    /// Lang1/Lang2(練習ページでは Caps Lock も)を消費したら true。それ以外は何もしない(false)。
    @discardableResult
    func handleLangPress(usage: Int, phase: LangKeyPhase) -> Bool {
        let consumed = langQueue.press(usage: usage, phase: phase)
        if consumed { pumpLang() }
        return consumed
    }

    /// 押したままの Lang キーすべてに keyup を送る(画面が消える・アプリが非アクティブ・押下の中断)
    func releaseAllLangKeys() {
        langQueue.cancelAll()
        pumpLang()
    }

    /// ページの読み込みが終わった: 失敗で止まっていた分を再開する
    func langPageReady() {
        retries = 0
        langQueue.pageReady()
        pumpLang()
    }

    private func pumpLang() {
        guard let script = langQueue.next() else { return }
        evaluateJavaScript(script) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.langQueue.complete(success: error == nil)
                if error == nil {
                    self.retries = 0
                    self.pumpLang()
                } else if self.retries < 3 {
                    // ページの遷移中などの失敗。同じものを先頭のまま、少し待って 1 本ずつ送り直す(順序は変えない)
                    self.retries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.langQueue.pageReady()
                        self?.pumpLang()
                    }
                }
            }
        }
    }

    // MARK: presses

    private func route(_ presses: Set<UIPress>, phase: LangKeyPhase) -> Set<UIPress> {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, handleLangPress(usage: Int(key.keyCode.rawValue), phase: phase) { continue }
            rest.insert(press)
        }
        return rest
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = route(presses, phase: .down)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = route(presses, phase: .up)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // 中断された Lang キーは離上として扱い、ページにキーが残らないようにする
        let rest = route(presses, phase: .up)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
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
