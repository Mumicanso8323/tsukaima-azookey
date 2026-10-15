# 指示書: Claude タブの Markdown 表示(パーサ+SwiftUI ビュー+コードの色付け)

対象リポジトリ: tsukaima-azookey(SwiftUI、iOS 17.6 以上、Swift 6 言語モード)。ブランチ claude-tab-v2 の上で作業する。
MainApp/ 以下は Xcode の同期グループなので、ファイルを置けば自動でアプリのターゲットに入る(pbxproj は触らない)。
azooKeyTests/ も同期グループで、置けば単体テストのターゲットに入る(`@testable import azooKey`)。

## 目的
Claude の返事(Markdown)を、公式の Claude iOS アプリと同じように読める形で表示する。いまは `Text(String)` で生のまま出ている。

## 作るもの(ファイル一覧 = これ以外は触らない)
1. `MainApp/Features/Claude/ClaudeMarkdown.swift` — **Foundation だけ**に依存するブロック解析器(SwiftUI/UIKit を import しない)。
2. `MainApp/Features/Claude/ClaudeMarkdownView.swift` — SwiftUI の表示部品。
3. `MainApp/Features/Claude/ClaudeCodeHighlighter.swift` — コードの簡易な色付け(Foundation だけ。色は「種類」を返し、色そのものはビュー側で決める)。
4. `azooKeyTests/ClaudeMarkdownTests.swift` — 解析器と色付けの単体テスト(XCTest)。
5. `scripts/claude-md-selftest.sh` — Linux の swiftc で 1・3 と、4 と同じ内容の確認を走らせる自己テスト(下の「受け入れ」)。

## 1. 解析器の公開 API(この名前・形で作る。ほかのファイルから使う)
```swift
enum MDAlign: Equatable, Sendable { case none, left, center, right }

struct MDListItem: Equatable, Sendable {
    var checked: Bool?        // "- [ ] " → false, "- [x] " → true, 普通の項目は nil
    var blocks: [MDBlock]     // 項目の中身(段落・入れ子のリスト・コードなど)
}

indirect enum MDBlock: Equatable, Sendable {
    case heading(level: Int, text: String)            // text はインラインの Markdown 原文
    case paragraph(String)                            // 段落内の改行(ソフト改行)は保持する
    case list(ordered: Bool, start: Int, items: [MDListItem])
    case code(language: String?, code: String)        // ``` と ~~~ のフェンス。インデント 4 のコードは扱わなくてよい
    case table(header: [String], alignments: [MDAlign], rows: [[String]])  // GFM の表。セルはインライン原文
    case quote([MDBlock])                             // > 引用(入れ子・中のリストも可)
    case rule                                         // ---, ***, ___
    case image(alt: String, source: String)           // 行全体が ![alt](src) だけのとき
}

enum ClaudeMarkdown {
    static func parse(_ source: String) -> [MDBlock]
}
```
要件:
- CommonMark/GFM の実用的な部分集合でよいが、Claude がよく出す形はすべて正しく扱う: ATX 見出し(#〜######)、
  段落、`-`/`*`/`+`/`1.`/`1)` のリスト(入れ子はインデント 2〜4 の両方)、タスクリスト、フェンス付きコード(言語名つき・
  閉じ忘れは最後まで)、GFM の表(区切り行の `:---:` で揃え。行の列数が足りなければ空で埋め、多ければ切る。
  セル中の `\|` はパイプとして扱う)、引用、水平線、行全体の画像。
- 閉じていないフェンス・空行だらけ・CRLF などで落ちない(クラッシュしない・無限ループしない)。10 万字を 50ms 程度で解析できる線形の実装。
- 見出しの末尾の `#` は取り除く。setext 見出し(=== / ---)は扱わなくてよい(`---` は水平線として扱う。ただし段落の直後の `---` は水平線でよい)。

## 2. インライン(ClaudeMarkdownView.swift の中、または ClaudeMarkdown.swift に Foundation だけで)
```swift
enum ClaudeInline {
    /// インライン原文 → AttributedString。太字・斜体・取り消し線・インラインコード・リンクを解釈する
    /// (Foundation の AttributedString(markdown:options: .inlineOnlyPreservingWhitespace) を使ってよい。失敗したら原文をそのまま)。
    /// さらに:
    ///   - 生の URL(https?://…)をリンクにする(すでにリンクの部分は触らない)。
    ///   - 絶対パス(`/data/ashwell/…`・`/home/ashwell/…`・`~/…` で始まり、空白・括弧・引用符で終わる)をリンクにする。
    ///     URL は `tsukaima-file://open?path=<パーセントエンコードした絶対パス>`(`~/` は `/home/ashwell/` に展開)。
    ///     インラインコードの中身がまるごとパスのときも同じくリンクにする。
    static func attributed(_ source: String) -> AttributedString
}
```
インラインコードは見た目の手がかりとして `inlinePresentationIntent` に `.code` が付いた状態にしておく(ビュー側で等幅・背景を付ける)。

## 3. 表示部品(SwiftUI)
```swift
struct ClaudeMarkdownView: View {
    let blocks: [MDBlock]
    init(blocks: [MDBlock])
    init(markdown: String)   // 内部で ClaudeMarkdown.parse(便利用。長文は呼び出し側で事前に解析した blocks を渡す)
}
```
- 文字は Dynamic Type に従う(`.body` などのテキストスタイル。固定 pt を使わない)。色は意味色(`.primary`・`.secondary`・
  `Color(.secondarySystemBackground)` など)でダークモードでも読めること。
- 段落・見出し・セルなどの `Text` は `.textSelection(.enabled)`。
- 見出し: level 1→`.title2.bold()`、2→`.title3.bold()`、3→`.headline`、4 以降→`.subheadline.bold()`。上に少し余白。
- リスト: 黒丸(入れ子で ◦ ▪)/番号、タスクは `checkmark.square` / `square`。項目の中のブロックを再帰で出す。左の字下げは入れ子ごとに一定。
- コードブロック: 角丸の背景、上に言語名(無ければ「コード」)と「コピー」ボタン(押すと UIPasteboard に入れて 1.5 秒「コピーしました」)。
  本文は `ScrollView(.horizontal)` の中で等幅(`.system(.callout, design: .monospaced)`)・折り返さない・選択できる。
  色付けは ClaudeCodeHighlighter の結果を AttributedString に反映。コピーボタンの accessibilityIdentifier は `claude.md.copyCode`。
- 表: `ScrollView(.horizontal)` の中に `Grid`。見出し行は太字・背景つき、罫線あり、揃えを守る。セルはインライン。
- 引用: 左に縦線、文字は `.secondary`、中身は再帰。
- 水平線: `Divider()`。
- 画像: `ClaudeMarkdownView` に `imageView` を差し込めるようにする: `init(blocks:, image: @escaping (String, String) -> AnyView = …)`
  の形などで、既定は `AsyncImage`(http(s) のみ。それ以外は「画像: alt」の 1 行)。
- リンクを押すと `@Environment(\.openURL)` に渡す(アプリ側で横取りしてアプリ内ブラウザ/ファイル閲覧を開く。ここでは何もしない)。
- 重くしない: `body` の中で解析しない(`init(markdown:)` は init で 1 回だけ解析して保持)。ハイライトもビューの init で 1 回。

## 4. コードの色付け
```swift
enum CodeTokenKind: Sendable { case plain, keyword, string, comment, number, type, function }
struct CodeToken: Equatable, Sendable { let range: Range<String.Index>; let kind: CodeTokenKind }
enum ClaudeCodeHighlighter {
    static func tokens(_ code: String, language: String?) -> [CodeToken]   // 重ならない・昇順。plain は省略してよい
}
```
- 言語: swift, python, javascript/js/jsx, typescript/ts/tsx, bash/sh/zsh/shell/console, json, yaml/yml, go, rust, c/cpp/objc, html/xml, css, sql, diff
  (diff は `+`/`-` 行を string/keyword 相当で色分けしてよい)。不明な言語は文字列・コメント・数値だけ。
- 1 文字ずつ走査する線形の手書き字句解析(正規表現の多重適用で遅くしない)。20 万字で 100ms 程度。
- ビュー側の色: keyword=紫系、string=赤茶系、comment=灰、number=青系、type=青緑系、function=水色系。ライト/ダーク両方で読める `Color(UIColor { trait in … })`。

## 5. 単体テスト(azooKeyTests/ClaudeMarkdownTests.swift)
最低限: 見出し(末尾 # 除去)、段落の改行保持、入れ子リスト(2 と 4 の字下げ)、番号の開始値、タスク、フェンス(言語名・~~~・閉じ忘れ)、
フェンス内の `#` や `|` が解釈されないこと、表(揃え・列数の過不足・`\|`)、引用の中のリスト、水平線、行全体の画像、CRLF、空文字、
`ClaudeInline.attributed` のパス→`tsukaima-file://` リンク(`~/` 展開を含む)と生 URL のリンク化、色付けのキーワード/文字列/コメントが重ならず昇順。

## 6. 受け入れ(この順に実行して全部通ること)
```bash
cd <worktree>
bash scripts/claude-md-selftest.sh      # 終了コード 0、最後に "selftest: N passed, 0 failed"(N>=25)
git diff --stat                          # 上の 5 ファイルだけが増えている
```
`scripts/claude-md-selftest.sh` は `~/.local/share/swiftly/bin/swiftc`(Swift 6.2、Linux)で
`ClaudeMarkdown.swift`・`ClaudeCodeHighlighter.swift` と、テストと同じ確認を書いた一時の main.swift を 1 つの実行ファイルにして走らせる
(XCTest は使わない。Linux の Foundation に `AttributedString(markdown:)` が無ければ、インラインの確認だけは
`#if canImport(Darwin)` で飛ばしてよい。ClaudeInline を ClaudeMarkdown.swift に置く場合も同様に Darwin 依存部分を分ける)。
SwiftUI のビューは Linux ではコンパイルできないので、型と API の名前を上の通りにし、明らかなコンパイルエラーが無いよう丁寧に書く
(Swift 6 の厳格な並行性: グローバルな可変状態を作らない、static let は Sendable な値だけ)。
