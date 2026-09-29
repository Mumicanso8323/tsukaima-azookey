//
//  HubUserDictionary.swift
//  使い魔azooKey
//
//  hub が育てるユーザ辞書を取り込み、azooKey の動的ユーザ辞書に混ぜる。
//  {"updated_at": ISO8601, "words": [{"word", "reading"(ひらがな), "hint"?}], "block"?: [String]}
//  block に入っている文字列を含む候補は表示しない(CandidateBlocklist)。
//  候補の長押し「この候補を出さない」はローカルの block.json に足す。
//
//  取得は本体アプリの TsukaimaAPI.shared が担い、App Group に書いた JSON(TsukaimaImeDict)を
//  ここで読むだけ。キーボード拡張はネットワーク(Tailscale 含む)に一切出ない。
//

import AzooKeyUtils
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import KeyboardViews

enum HubUserDictionary {
    typealias Payload = TsukaimaImeDict.Payload
    typealias Word = TsukaimaImeDict.Word

    /// 動的辞書は線形検索なので上限を設ける
    static let maxWords = 20000
    /// 本体アプリ側の取得間隔と揃えておく(cacheIsFresh の目安値)
    static let interval: TimeInterval = TsukaimaImeDict.minFetchInterval

    // MARK: - 純粋関数(テスト対象)

    static func decode(_ data: Data) -> Payload? {
        try? JSONDecoder().decode(Payload.self, from: data)
    }

    static func elements(_ payload: Payload) -> [DicdataElement] {
        payload.words.prefix(maxWords).compactMap { w in
            let word = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let reading = w.reading.trimmingCharacters(in: .whitespacesAndNewlines)
            let ruby = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
            guard !word.isEmpty, !ruby.isEmpty else {
                return nil
            }
            return DicdataElement(word: word, ruby: ruby, cid: cid(w.hint), mid: MIDData.一般.mid, value: -5)
        }
    }

    /// hint が品詞らしければ使う。それ以外は一般名詞扱い
    static func cid(_ hint: String?) -> Int {
        switch hint {
        case "人名": CIDData.人名一般.cid
        case "姓": CIDData.人名姓.cid
        case "名": CIDData.人名名.cid
        case "地名": CIDData.地名一般.cid
        case "組織": CIDData.固有名詞組織.cid
        case "固有名詞": CIDData.固有名詞.cid
        default: CIDData.一般名詞.cid
        }
    }

    /// ローカル block に 1 件足した新しいリスト(重複・空は足さない)
    static func appending(_ text: String, to list: [String]) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !list.contains(t) else {
            return list
        }
        return list + [t]
    }

    // MARK: - 保存先

    static func directory(base: URL) -> URL {
        let dir = base.appendingPathComponent("tsukaima", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 本体アプリが TsukaimaAPI.shared で取得して書いたキャッシュ(TsukaimaImeDict と同じ場所)
    static func cacheURL(base: URL) -> URL { TsukaimaImeDict.fileURL(base: base) }
    static func localBlockURL(base: URL) -> URL { directory(base: base).appendingPathComponent("block.json") }

    static func loadCache(base: URL) -> Payload? {
        (try? Data(contentsOf: cacheURL(base: base))).flatMap(decode)
    }

    static func loadLocalBlock(base: URL) -> [String] {
        (try? Data(contentsOf: localBlockURL(base: base)))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    static func saveLocalBlock(_ list: [String], base: URL) {
        try? JSONEncoder().encode(list).write(to: localBlockURL(base: base), options: .atomic)
    }

    /// キャッシュファイルの更新日時(無ければ nil)。mtime が変わったかどうかの判定に使う
    static func cacheModificationDate(base: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL(base: base).path)
        return attrs?[.modificationDate] as? Date
    }

    static func cacheIsFresh(base: URL, now: Date = Date()) -> Bool {
        guard let modified = cacheModificationDate(base: base) else {
            return false
        }
        return now.timeIntervalSince(modified) < interval
    }
}

/// OS のユーザ辞書・連絡先(azooKey 本来の動的辞書)と hub の辞書を合わせて converter に渡す
@MainActor
final class DynamicDictionaryComposer {
    private var baseEntries: [DicdataElement] = []
    private var hubEntries: [DicdataElement] = []
    /// 直近に読み込んだキャッシュの mtime。nil はまだ一度も読めていない(ファイル無し含む)
    private var hubCacheModified: Date?
    private let storageBase: URL
    private let apply: @MainActor ([DicdataElement]) -> Void

    init(storageBase: URL, apply: @escaping @MainActor ([DicdataElement]) -> Void) {
        self.storageBase = storageBase
        self.apply = apply
        CandidateBlocklist.shared.setLocalPatterns(HubUserDictionary.loadLocalBlock(base: storageBase))
        reloadHubCacheIfChanged()
    }

    /// azooKey 本来の動的辞書(OS ユーザ辞書・連絡先)を差し替える
    func setBaseEntries(_ entries: [DicdataElement]) {
        baseEntries = entries
        apply(baseEntries + hubEntries)
    }

    /// 本体アプリが App Group に書いたキャッシュを、mtime が変わっていれば読み直す。
    /// キーボード拡張はここではネットワークに一切出ない(取得は本体アプリの役目)。
    func refreshHub() {
        if reloadHubCacheIfChanged() {
            apply(baseEntries + hubEntries)
        }
    }

    func addLocalBlock(_ text: String) {
        let list = HubUserDictionary.appending(text, to: HubUserDictionary.loadLocalBlock(base: storageBase))
        HubUserDictionary.saveLocalBlock(list, base: storageBase)
        CandidateBlocklist.shared.setLocalPatterns(list)
    }

    /// mtime が変わっていれば読み直して true を返す(変わっていなければ何もせず false)
    @discardableResult
    private func reloadHubCacheIfChanged() -> Bool {
        let modified = HubUserDictionary.cacheModificationDate(base: storageBase)
        guard modified != hubCacheModified else {
            return false
        }
        hubCacheModified = modified
        guard let payload = HubUserDictionary.loadCache(base: storageBase) else {
            hubEntries = []
            CandidateBlocklist.shared.setHubPatterns([])
            return true
        }
        hubEntries = HubUserDictionary.elements(payload)
        CandidateBlocklist.shared.setHubPatterns(payload.block ?? [])
        return true
    }
}
