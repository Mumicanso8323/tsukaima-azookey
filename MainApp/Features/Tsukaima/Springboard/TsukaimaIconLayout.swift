import Foundation

/// ホーム画面のアイコン配置(SpringBoard の icon state)の純粋なモデル・差分・適用ロジック。
/// FFI もネットワークも触らない(実機なしでも読める/後でテストを足せる)。
///
/// 表現は 2 層:
/// - `xml: Data` — 端末から受け取った plist を XML のまま保持する。`set_icon_state` に戻すのも
///   バックアップに書くのもこれ。ウィジェット等の未知の項目を壊さないため、**辞書の中身は
///   触らず並べ替えるだけ**にする(`apply` は既存の辞書を拾って新しい順に並べ直す)。
/// - `Entry` の木 — 画面表示と差分計算のための型付きの写し。`[String: Any]` は Sendable でないので
///   MainActor に渡すのはこちらと `xml` だけ(Swift 6 の並行性チェック対策)。
///
/// キー名は libimobiledevice の sbservices / iOS の IconState.plist で広く知られているもの
/// (`iconLists` = ページの配列、`buttonBar` = Dock、`displayIdentifier` = bundle id、
/// `listType == "folder"` + `displayName` + 入れ子の `iconLists` = フォルダ)。実機で違えば
/// ここだけ直す(docs/tsukaima-springboard-icon-integration.md §7 の実機確認 2)。
enum TsukaimaIconLayoutError: LocalizedError {
    case xmlDecodeFailed
    case xmlEncodeFailed
    case proposalDecodeFailed(String)
    case proposalDuplicate(String)
    case proposalDuplicateFolder(String)

    var errorDescription: String? {
        switch self {
        case .xmlDecodeFailed: "配置データ(plist)を読み取れませんでした"
        case .xmlEncodeFailed: "配置データ(plist)を書き出せませんでした"
        case .proposalDecodeFailed(let why): "配置案の JSON を読み取れませんでした: \(why)"
        case .proposalDuplicate(let id): "配置案に同じアプリが 2 回出てきます: \(id)"
        case .proposalDuplicateFolder(let name): "配置案に同じ名前のフォルダが 2 回出てきます: \(name)"
        }
    }
}

/// 画面表示・差分用の型付きの写し
struct TsukaimaIconState: Sendable, Equatable {
    indirect enum Entry: Sendable, Equatable {
        case app(String)                                   // bundle id
        case folder(name: String, pages: [[Entry]])
        case other(String)                                 // ウィジェット等。文字列は種別の要約(表示用)
    }

    var xml: Data
    var dock: [Entry]
    var pages: [[Entry]]
    var topLevelKeys: [String]

    var pageCount: Int { pages.count }
    var dockAppCount: Int { dock.count }

    /// bundle id → 場所の説明("Dock" / "2ページ目" / "2ページ目 › 仕事")
    func locations() -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ entries: [Entry], place: String) {
            for e in entries {
                switch e {
                case .app(let id): out[id] = place
                case .folder(let name, let pages):
                    for p in pages { walk(p, place: "\(place) › \(name)") }
                case .other: break
                }
            }
        }
        walk(dock, place: "Dock")
        for (i, p) in pages.enumerated() { walk(p, place: "\(i + 1)ページ目") }
        return out
    }

    /// 全アプリの bundle id(重複なし・出現順)
    func allAppIDs() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func walk(_ entries: [Entry]) {
            for e in entries {
                switch e {
                case .app(let id): if seen.insert(id).inserted { out.append(id) }
                case .folder(_, let pages): pages.forEach(walk)
                case .other: break
                }
            }
        }
        walk(dock)
        pages.forEach(walk)
        return out
    }

    func folderNames() -> [String] {
        var out: [String] = []
        func walk(_ entries: [Entry]) {
            for e in entries {
                if case .folder(let name, let pages) = e {
                    out.append(name)
                    pages.forEach(walk)
                }
            }
        }
        walk(dock)
        pages.forEach(walk)
        return out
    }
}

/// サーバー(hub)または手貼りの JSON で受け取る配置案。形式は
/// docs/tsukaima-springboard-icon-integration.md §8 に記載。
struct TsukaimaIconProposal: Sendable, Equatable {
    indirect enum Item: Sendable, Equatable {
        case app(String)
        case folder(name: String, pages: [[String]])
    }

    var version: Int
    var note: String?
    var dock: [String]            // 空なら「今の Dock を維持」
    var pages: [[Item]]
    /// 配置案に出てこない端末上のアプリの扱い。"append"(既定) = 末尾に新しいページを足して並べる /
    /// "keep" = 元のページ番号に残す
    var unlisted: String

    static func parse(json: Data) throws -> TsukaimaIconProposal {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: json)
        } catch {
            throw TsukaimaIconLayoutError.proposalDecodeFailed("JSON として不正")
        }
        guard let root = obj as? [String: Any] else {
            throw TsukaimaIconLayoutError.proposalDecodeFailed("トップレベルがオブジェクトではない")
        }
        let version = root["version"] as? Int ?? 1
        guard version == 1 else {
            throw TsukaimaIconLayoutError.proposalDecodeFailed("version \(version) は未対応(1 のみ)")
        }
        var dock: [String] = []
        for raw in root["dock"] as? [Any] ?? [] {
            guard let id = raw as? String else { throw TsukaimaIconLayoutError.proposalDecodeFailed("dock に文字列でない項目がある") }
            dock.append(id)
        }
        guard let rawPages = root["pages"] as? [Any] else {
            throw TsukaimaIconLayoutError.proposalDecodeFailed("pages がない")
        }
        var pages: [[Item]] = []
        for (pi, rawPage) in rawPages.enumerated() {
            guard let rawItems = rawPage as? [Any] else {
                throw TsukaimaIconLayoutError.proposalDecodeFailed("pages[\(pi)] が配列ではない")
            }
            var items: [Item] = []
            for raw in rawItems {
                if let id = raw as? String {
                    items.append(.app(id))
                } else if let dict = raw as? [String: Any], let name = dict["folder"] as? String {
                    var fpages: [[String]] = []
                    for rawFPage in dict["pages"] as? [Any] ?? [] {
                        guard let rawIDs = rawFPage as? [Any] else {
                            throw TsukaimaIconLayoutError.proposalDecodeFailed("フォルダ「\(name)」の pages が配列の配列ではない")
                        }
                        var ids: [String] = []
                        for rawID in rawIDs {
                            guard let id = rawID as? String else {
                                throw TsukaimaIconLayoutError.proposalDecodeFailed("フォルダ「\(name)」の中に文字列でない項目がある")
                            }
                            ids.append(id)
                        }
                        fpages.append(ids)
                    }
                    items.append(.folder(name: name, pages: fpages.isEmpty ? [[]] : fpages))
                } else {
                    throw TsukaimaIconLayoutError.proposalDecodeFailed("pages[\(pi)] に文字列でも {\"folder\": …} でもない項目がある")
                }
            }
            pages.append(items)
        }
        let unlisted = root["unlisted"] as? String ?? "append"
        guard unlisted == "append" || unlisted == "keep" else {
            throw TsukaimaIconLayoutError.proposalDecodeFailed("unlisted は \"append\" か \"keep\"")
        }
        var seen = Set<String>()
        var seenFolders = Set<String>()
        for id in dock { guard seen.insert(id).inserted else { throw TsukaimaIconLayoutError.proposalDuplicate(id) } }
        for page in pages {
            for item in page {
                switch item {
                case .app(let id):
                    guard seen.insert(id).inserted else { throw TsukaimaIconLayoutError.proposalDuplicate(id) }
                case .folder(let name, let fpages):
                    guard seenFolders.insert(name).inserted else { throw TsukaimaIconLayoutError.proposalDuplicateFolder(name) }
                    for fp in fpages {
                        for id in fp { guard seen.insert(id).inserted else { throw TsukaimaIconLayoutError.proposalDuplicate(id) } }
                    }
                }
            }
        }
        return TsukaimaIconProposal(version: version, note: root["note"] as? String, dock: dock, pages: pages, unlisted: unlisted)
    }
}

/// 差分の 1 行(画面にそのまま並べる)
struct TsukaimaIconDiffLine: Sendable, Identifiable, Equatable {
    enum Kind: Sendable, Equatable { case moved, folderAdded, folderRemoved, unlisted, missing, warning }
    var id: String { "\(kind)-\(text)" }
    var kind: Kind
    var text: String
}

struct TsukaimaIconApplyResult: Sendable {
    var newState: TsukaimaIconState
    var diff: [TsukaimaIconDiffLine]
    var changedAppCount: Int
}

enum TsukaimaIconLayout {
    /// iPhone の 1 ページに載る目安(4×6)。超えたら警告するだけ(端末によって違うので止めない)
    static let iconsPerPageHint = 24
    static let dockHint = 4

    // MARK: plist XML ⇄ 型付き

    static func parse(xml: Data) throws -> TsukaimaIconState {
        let dict = try decodeDict(xml)
        let dock = entries(from: dict["buttonBar"])
        let pages = (dict["iconLists"] as? [Any] ?? []).map { entries(from: $0) }
        return TsukaimaIconState(xml: xml, dock: dock, pages: pages, topLevelKeys: Array(dict.keys).sorted())
    }

    private static func decodeDict(_ xml: Data) throws -> [String: Any] {
        guard let obj = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let dict = obj as? [String: Any] else {
            throw TsukaimaIconLayoutError.xmlDecodeFailed
        }
        return dict
    }

    private static func encodeDict(_ dict: [String: Any]) throws -> Data {
        do {
            return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        } catch {
            throw TsukaimaIconLayoutError.xmlEncodeFailed
        }
    }

    private static func entries(from raw: Any?) -> [TsukaimaIconState.Entry] {
        (raw as? [Any] ?? []).map { entry(from: $0) }
    }

    private static func entry(from raw: Any) -> TsukaimaIconState.Entry {
        guard let dict = raw as? [String: Any] else { return .other("不明") }
        if isFolder(dict) {
            let name = dict["displayName"] as? String ?? "(名前なし)"
            let pages = (dict["iconLists"] as? [Any] ?? []).map { entries(from: $0) }
            return .folder(name: name, pages: pages)
        }
        if let id = appID(dict) { return .app(id) }
        let kind = (dict["iconType"] as? String) ?? (dict["elementType"] as? String) ?? (dict["listType"] as? String) ?? "ウィジェット等"
        return .other(kind)
    }

    private static func isFolder(_ dict: [String: Any]) -> Bool {
        (dict["listType"] as? String) == "folder" || (dict["iconLists"] != nil && dict["displayName"] != nil)
    }

    private static func appID(_ dict: [String: Any]) -> String? {
        if let s = dict["displayIdentifier"] as? String, !s.isEmpty { return s }
        if let s = dict["bundleIdentifier"] as? String, !s.isEmpty { return s }
        return nil
    }

    // MARK: 適用

    /// 現在の配置(xml)に配置案を当てて、新しい配置(xml + 型付き)と差分を返す。
    /// 端末上の辞書(アプリ・フォルダ・その他)は中身を変えずに並べ直す。
    static func apply(_ proposal: TsukaimaIconProposal, to currentXML: Data) throws -> TsukaimaIconApplyResult {
        let current = try parse(xml: currentXML)
        let dict = try decodeDict(currentXML)

        // 端末上の辞書を拾う
        var appDicts: [String: [String: Any]] = [:]
        var folderDicts: [String: [String: Any]] = [:]
        var othersByPage: [Int: [[String: Any]]] = [:]      // ページ番号(0 始まり) → その他の辞書
        var othersInFolder: [String: [[String: Any]]] = [:]  // フォルダ名 → その他の辞書
        func collect(_ raw: Any?, pageIndex: Int, folderName: String?) {
            for item in raw as? [Any] ?? [] {
                guard let d = item as? [String: Any] else { continue }
                if isFolder(d) {
                    let name = d["displayName"] as? String ?? "(名前なし)"
                    if folderDicts[name] == nil { folderDicts[name] = d }
                    for p in d["iconLists"] as? [Any] ?? [] { collect(p, pageIndex: pageIndex, folderName: name) }
                } else if let id = appID(d) {
                    if appDicts[id] == nil { appDicts[id] = d }
                } else if let folderName {
                    othersInFolder[folderName, default: []].append(d)
                } else {
                    othersByPage[pageIndex, default: []].append(d)
                }
            }
        }
        collect(dict["buttonBar"], pageIndex: -1, folderName: nil)
        for (i, p) in (dict["iconLists"] as? [Any] ?? []).enumerated() { collect(p, pageIndex: i, folderName: nil) }

        var diff: [TsukaimaIconDiffLine] = []
        var placed = Set<String>()
        var missing: [String] = []

        func takeApp(_ id: String) -> [String: Any]? {
            guard let d = appDicts[id] else { missing.append(id); return nil }
            placed.insert(id)
            return d
        }

        func buildFolder(name: String, pages: [[String]]) -> [String: Any] {
            var fd: [String: Any] = folderDicts[name] ?? ["displayName": name, "listType": "folder"]
            var newPages: [[[String: Any]]] = pages.map { $0.compactMap(takeApp) }
            if let extras = othersInFolder.removeValue(forKey: name), !extras.isEmpty {
                if newPages.isEmpty { newPages = [[]] }
                newPages[0].append(contentsOf: extras)
            }
            newPages = newPages.filter { !$0.isEmpty }
            fd["iconLists"] = newPages.isEmpty ? [[]] : newPages
            fd["displayName"] = name
            fd["listType"] = "folder"
            return fd
        }

        // Dock
        var newDock: [[String: Any]] = []
        var keptDockFolders = Set<String>()
        if proposal.dock.isEmpty {
            for item in dict["buttonBar"] as? [Any] ?? [] {
                guard let d = item as? [String: Any] else { continue }
                if isFolder(d) {
                    let name = d["displayName"] as? String ?? "(名前なし)"
                    var ids: [[String]] = []
                    for rawPage in d["iconLists"] as? [Any] ?? [] {
                        var pageIDs: [String] = []
                        for rawIcon in rawPage as? [Any] ?? [] {
                            if let iconDict = rawIcon as? [String: Any], let id = appID(iconDict) { pageIDs.append(id) }
                        }
                        ids.append(pageIDs)
                    }
                    keptDockFolders.insert(name)
                    newDock.append(buildFolder(name: name, pages: ids))
                } else if let id = appID(d) {
                    if let ad = takeApp(id) { newDock.append(ad) }
                } else {
                    newDock.append(d)
                }
            }
        } else {
            newDock = proposal.dock.compactMap(takeApp)
            if let extras = othersByPage.removeValue(forKey: -1) { newDock.append(contentsOf: extras) }
        }
        if newDock.count > dockHint {
            diff.append(.init(kind: .warning, text: "Dock が \(newDock.count) 個(iPhone は通常 \(dockHint) 個まで)"))
        }

        // ページ
        var newPages: [[[String: Any]]] = []
        for (pi, page) in proposal.pages.enumerated() {
            var out: [[String: Any]] = []
            for item in page {
                switch item {
                case .app(let id):
                    if let d = takeApp(id) { out.append(d) }
                case .folder(let name, let fpages):
                    out.append(buildFolder(name: name, pages: fpages))
                }
            }
            if let extras = othersByPage.removeValue(forKey: pi) { out.append(contentsOf: extras) }
            if out.count > iconsPerPageHint {
                diff.append(.init(kind: .warning, text: "\(pi + 1)ページ目が \(out.count) 個(目安 \(iconsPerPageHint) 個)"))
            }
            newPages.append(out)
        }

        // 配置案に出てこないアプリ・フォルダの中身・その他
        var unlisted = current.allAppIDs().filter { !placed.contains($0) }
        // 配置案に出てこないフォルダの中のアプリも unlisted に含まれている(allAppIDs はフォルダの中も走査する)。
        // そのフォルダ自体は消える(中身は外に出る)ので差分に出す。
        var mentionedFolders = Set<String>()
        for page in proposal.pages {
            for item in page {
                if case .folder(let name, _) = item { mentionedFolders.insert(name) }
            }
        }
        for name in current.folderNames() where !mentionedFolders.contains(name) && !keptDockFolders.contains(name) {
            diff.append(.init(kind: .folderRemoved, text: "フォルダ「\(name)」は無くなる(中身は外に出る)"))
        }
        for name in mentionedFolders where folderDicts[name] == nil {
            diff.append(.init(kind: .folderAdded, text: "フォルダ「\(name)」を新しく作る"))
        }
        let before = current.locations()
        if proposal.unlisted == "keep" {
            // 元のページ番号に残す(ページが無ければ末尾に足す)
            for id in unlisted {
                guard let d = takeApp(id) else { continue }
                let place = before[id] ?? ""
                let pageNo = Int(place.prefix { $0.isNumber }) ?? (newPages.count + 1)
                while newPages.count < pageNo { newPages.append([]) }
                newPages[pageNo - 1].append(d)
            }
            unlisted = []
        }
        // ページの数が確定した後で、配置案に出てこないページの「その他」(ウィジェット等)を元のページ番号へ戻す。
        // フォルダ内の「その他」で行き場が無くなったものは末尾ページへ。
        var leftoverOthers: [[String: Any]] = othersInFolder.values.flatMap { $0 }
        for (pi, extras) in othersByPage.sorted(by: { $0.key < $1.key }) {
            if pi >= 0, pi < newPages.count { newPages[pi].append(contentsOf: extras) } else { leftoverOthers.append(contentsOf: extras) }
        }
        if !unlisted.isEmpty {
            diff.append(.init(kind: .unlisted, text: "配置案に無いアプリ \(unlisted.count) 個は末尾のページに並べる"))
            var chunk: [[String: Any]] = []
            for id in unlisted {
                guard let d = takeApp(id) else { continue }
                chunk.append(d)
                if chunk.count == iconsPerPageHint { newPages.append(chunk); chunk = [] }
            }
            if !chunk.isEmpty { newPages.append(chunk) }
        }
        if !leftoverOthers.isEmpty {
            diff.append(.init(kind: .unlisted, text: "ウィジェット等 \(leftoverOthers.count) 個は末尾のページに残す"))
            newPages.append(leftoverOthers)
        }
        if newPages.isEmpty { newPages = [[]] }
        for id in missing {
            diff.append(.init(kind: .missing, text: "\(id) は端末に無いので無視"))
        }

        var newDict = dict
        newDict["buttonBar"] = newDock
        newDict["iconLists"] = newPages
        let newXML = try encodeDict(newDict)
        let newState = try parse(xml: newXML)

        // 移動したアプリ
        let after = newState.locations()
        var changed = 0
        for id in current.allAppIDs() {
            let b = before[id] ?? "?"
            let a = after[id] ?? "(消える)"
            if a != b {
                changed += 1
                diff.append(.init(kind: .moved, text: "\(id): \(b) → \(a)"))
            }
        }
        // 種別順に並べ替え(警告→フォルダ→未指定→移動→端末に無い)
        let order: [TsukaimaIconDiffLine.Kind] = [.warning, .folderAdded, .folderRemoved, .unlisted, .moved, .missing]
        diff.sort { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
        return TsukaimaIconApplyResult(newState: newState, diff: diff, changedAppCount: changed)
    }

    // MARK: 現在の配置を hub に送る形(配置案と同じ JSON 形式)

    static func exportJSON(_ state: TsukaimaIconState) -> [String: Any] {
        func appIDs(_ entries: [TsukaimaIconState.Entry]) -> [String] {
            var out: [String] = []
            for e in entries {
                if case .app(let id) = e { out.append(id) }
            }
            return out
        }
        func items(_ entries: [TsukaimaIconState.Entry]) -> [Any] {
            var out: [Any] = []
            for e in entries {
                switch e {
                case .app(let id):
                    out.append(id)
                case .folder(let name, let pages):
                    let folder: [String: Any] = ["folder": name, "pages": pages.map(appIDs)]
                    out.append(folder)
                case .other(let kind):
                    let other: [String: Any] = ["other": kind]
                    out.append(other)
                }
            }
            return out
        }
        return [
            "version": 1,
            "dock": appIDs(state.dock),
            "pages": state.pages.map(items),
        ]
    }
}
