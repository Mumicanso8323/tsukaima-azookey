# 指示書: Claude タブのビューア群(アプリ内ブラウザ・ファイル閲覧・画像の拡大・テキスト選択・ファイル一覧)

対象: tsukaima-azookey(SwiftUI、iOS 17.6 以上、Swift 6 言語モード・厳格な並行性)。ブランチ claude-tab-v2 の上。
MainApp/ は Xcode の同期グループなので、ファイルを置けば自動でアプリに入る(pbxproj は触らない)。

## 前提(すでにあるもの。変えない)
- `MainApp/Features/Claude/ClaudeViewerRouter.swift`: `ClaudeSheet`(browser/file/image/selectText/files)と
  `ClaudeViewerRouter`(`@Published var sheet: ClaudeSheet?`、`openFile(_:)`・`open(_:)` など)。**この指示書のビューは router を通して開かれる。**
- `ClaudeTranscript.swift` の `ClaudeFileKind(path:)`(拡張子から image/pdf/html/markdown/csv/code/text/office/other)。
- `ClaudeMarkdown.swift`・`ClaudeMarkdownView.swift`・`ClaudeCodeHighlighter.swift`(Markdown の表示とコードの色付け)。
- `ClaudeConfig.isMock`(UI テスト用の起動引数 `--claude-mock`。true のときはネットワークに出ず、下の「偽のデータ」を返す)。
- 認証つきの要求: `TsukaimaEndpoint.request(url)`(端末の合鍵を載せる)、URL は `TsukaimaEndpoint.url("/api/...")`。
- サーバーの API(portal-bot。docs/converse-protocol.md 2章の HTTP):
  - `GET /api/claude/file?path=<絶対パス>` → 中身(Content-Type 付き)。403=許可されていない場所/秘密、404=無い、413=50MB 超、400=フォルダ等。
  - `GET /api/claude/files?dir=<絶対パス>` → `{"dir","parent","entries":[{"name","path","is_dir","size","mtime"}],"truncated"}`。
    dir 省略で `{"dir":null,"parent":null,"entries":[{"name","path","is_dir":true}]}`(ルートの一覧)。

## 作るファイル(これ以外は触らない。ClaudeViewerRouter.swift に `.claudeSheets(router)` の修飾子を足すのは可)
1. `MainApp/Features/Claude/ClaudeFileStore.swift`
2. `MainApp/Features/Claude/ClaudeViewers.swift`(シートの中身の振り分け・ブラウザ・テキスト選択・画像)
3. `MainApp/Features/Claude/ClaudeFileViewer.swift`(ファイル閲覧・HTML・コード・CSV・ファイル一覧)

## 1. ClaudeFileStore(通信とキャッシュ)
```swift
struct ClaudeDirEntry: Identifiable, Equatable, Sendable { let name: String; let path: String; let isDir: Bool; let size: Int?; let mtime: String?; var id: String { path } }
struct ClaudeDirListing: Equatable, Sendable { let dir: String?; let parent: String?; let entries: [ClaudeDirEntry]; let truncated: Bool }
enum ClaudeFileError: LocalizedError, Equatable { case forbidden, notFound, tooLarge, notAFile, network(String), status(Int)
    var errorDescription: String? { … 日本語。forbidden=「許可されていない場所か、見せない種類のファイルです」など } }
actor ClaudeFileStore {
    static let shared: ClaudeFileStore
    /// ファイルを落として、端末内の一時ファイルの URL を返す(Caches/claude-files/<パスの SHA256 の先頭 16 桁>/<元のファイル名>)。
    /// 同じパスは 60 秒以内なら落とし直さない。
    func fetch(path: String) async throws -> URL
    /// 画像の縮小表示用(メモリにも 50 件ほど置く)
    func data(path: String) async throws -> Data
    func list(dir: String?) async throws -> ClaudeDirListing
}
```
- HTTP のステータスを ClaudeFileError に対応させる。タイムアウト 60 秒。
- **偽のデータ(isMock のとき)**: ネットワークに出ず、パスの拡張子に応じて中身を作って返す:
  .md=見出し・リスト・コードを含む短い文、.html=`<h1>モックの成果物</h1><p id="mock">表示できています</p>`、
  .png/.jpg=UIGraphicsImageRenderer で描いた 400x300 の色付き画像、.csv=3 列 4 行、.swift/.py などのコード=20 行ほど、
  .pdf=UIGraphicsPDFRenderer で 1 ページ、それ以外=プレーンテキスト。パスに "forbidden" を含むと `.forbidden` を投げる。
  一覧は `/mock`(フォルダ `docs`、ファイル `report.html`・`notes.md`・`data.csv`・`main.swift`・`photo.png`)、`/mock/docs`(`plan.md`)、
  dir=nil は `/mock` 1 つだけのルート一覧。

## 2. ClaudeViewers.swift
```swift
extension View { func claudeSheets(_ router: ClaudeViewerRouter) -> some View }   // .sheet(item: $router.sheet) で下の中身を出す。router を environmentObject で渡す
struct ClaudeSheetContent: View { let sheet: ClaudeSheet }
struct ClaudeSafariView: UIViewControllerRepresentable { let url: URL }           // SFSafariViewController(「Safari で開く」は標準のボタンで選べる)
struct ClaudeTextSelectView: View { let text: String }                          // 編集不可・選択可の UITextView に全文。ツールバーに「完了」「すべてコピー」
struct ClaudeImageViewer: View { let source: String }                           // 黒背景・ピンチで拡大・ダブルタップで拡大/戻す・「完了」・ShareLink(画像)
struct ClaudeRemoteImage: View { let source: String; var maxPixel: CGFloat = 600 }  // 縮小表示。ImageIO で縮小デコード。読み込み中は灰色の枠、失敗は photo のアイコン
```
- source が `http(s)://` なら URLSession(合鍵は付けない)、それ以外は hub のパスとして ClaudeFileStore.data。
- 拡大は UIScrollView(UIViewRepresentable)で実装(SwiftUI の MagnificationGesture は使わない)。
- accessibilityIdentifier: ブラウザのシートの外枠 `claude.browser`、テキスト選択 `claude.selectText`、画像ビューア `claude.imageViewer`、
  各シートの「完了」ボタン `claude.sheet.done`。

## 3. ClaudeFileViewer.swift
```swift
struct ClaudeFileViewer: View { let path: String }          // NavigationStack 付き(シートの中身)。タイトルはファイル名
struct ClaudeFileContentView: View { let path: String }     // NavigationStack なし(一覧から push するとき用)。読み込み→種類ごとの表示
struct ClaudeFileBrowser: View { let startDir: String? }    // NavigationStack。フォルダは push、ファイルは ClaudeFileContentView を push
```
種類ごとの表示(ClaudeFileKind で振り分け):
- html: WKWebView。`WKURLSchemeHandler` で `tsukaima-file` スキームを受け、`tsukaima-file:///絶対パス` を ClaudeFileStore.fetch で返す
  (HTML の中の相対パスの css・画像もそのまま読める)。最初の読み込みも `tsukaima-file:///<パス>` で。
  http(s) へのリンクを押したら `UIApplication.shared.open`(外の Safari)。JavaScript は有効。
- markdown: `ClaudeMarkdownView(markdown:)` を ScrollView で。右上で「原文」に切り替え(等幅の選択できる全文)。
- csv/tsv: 簡単な RFC 4180 の解析(引用符・改行入りセル)→ 縦横にスクロールする表(見出し行は太字・背景。最大 1000 行、超えたら末尾に「…ほか N 行」)。
- code/text: 行番号つき、ClaudeCodeHighlighter で色付け(言語は拡張子から)。縦横スクロール、選択できる。1MB を超えたら先頭 1MB だけ+注意書き。
- image: ClaudeImageViewer と同じ拡大できる表示(背景はシステム色)。
- pdf/office/other: QuickLook(`QLPreviewController` を UIViewControllerRepresentable で)。
- ツールバー: 「完了」(`claude.sheet.done`)、ShareLink(落とした一時ファイル。「他のアプリで開く」「ファイルに保存」もここから)、メニューに「パスをコピー」。
- 読み込み中は ProgressView、失敗は ClaudeFileError の日本語+「もう一度」ボタン。
- 一覧: 名前・アイコン(フォルダ / ClaudeFileKind.icon)・大きさ(ByteCountFormatter)・更新日時。上に今のフォルダのパス。`truncated` なら末尾に注意書き。
- accessibilityIdentifier: ファイル閲覧の外枠 `claude.fileViewer`、HTML の WKWebView `claude.fileViewer.html`、一覧 `claude.files`、
  一覧の各行は `claude.files.row.<name>`。

## 品質
- 文字は Dynamic Type に従う。色は意味色(ダークモードで読める)。
- 重い処理(CSV の解析・色付け・画像の縮小)はメインスレッドで長く止めない(Task.detached か actor で)。
- Swift 6 の厳格な並行性でコンパイルが通るように(UI は @MainActor、actor 境界を越える値は Sendable)。

## 受け入れ
- Linux ではコンパイルできないので、型・API 名・identifier を上の通りにし、`git diff --stat` が上の 3 ファイル(と ClaudeViewerRouter.swift の小さな追記)だけであること。
- 自分で読み直して、iOS 17.6 で使えない API(iOS 18 以降のもの)は `if #available` で囲む。
