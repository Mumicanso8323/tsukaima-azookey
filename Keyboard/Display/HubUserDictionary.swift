//
//  HubUserDictionary.swift
//  使い魔azooKey
//
//  hub が育てるユーザ辞書を取り込み、azooKey の動的ユーザ辞書に混ぜる。
//  GET /api/ime/dict → {"updated_at": ISO8601, "words": [{"word", "reading"(ひらがな), "hint"?}], "block"?: [String]}
//  block に入っている文字列を含む候補は表示しない(CandidateBlocklist)。
//  候補の長押し「この候補を出さない」はローカルの block.json に足す。
//

import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import KeyboardViews

enum HubUserDictionary {
    static let url = URL(string: "https://ashwell-hub.taila653da.ts.net/api/ime/dict")!
    /// 動的辞書は線形検索なので上限を設ける
    static let maxWords = 20000
    /// キーボードは頻繁に出るので取得は 10 分に 1 回まで
    static let interval: TimeInterval = 10 * 60

    struct Payload: Codable, Equatable {
        var updated_at: String?
        var words: [Word]
        var block: [String]?
    }

    struct Word: Codable, Equatable {
        var word: String
        var reading: String
        var hint: String?
    }

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

    static func cacheURL(base: URL) -> URL { directory(base: base).appendingPathComponent("hub-dict.json") }
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

    static func cacheIsFresh(base: URL, now: Date = Date()) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL(base: base).path)
        guard let modified = attrs?[.modificationDate] as? Date else {
            return false
        }
        return now.timeIntervalSince(modified) < interval
    }

    /// 取得に成功したときだけ done を呼ぶ。失敗・オフラインは黙ってキャッシュのまま
    static func fetch(base: URL, force: Bool = false, _ done: @escaping @Sendable (Payload) -> Void) {
        if !force && cacheIsFresh(base: base) {
            return
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let payload = decode(data) else {
                return
            }
            try? data.write(to: cacheURL(base: base), options: .atomic)
            done(payload)
        }.resume()
    }
}

/// OS のユーザ辞書・連絡先(azooKey 本来の動的辞書)と hub の辞書を合わせて converter に渡す
@MainActor
final class DynamicDictionaryComposer {
    private var baseEntries: [DicdataElement] = []
    private var hubEntries: [DicdataElement] = []
    private var hubLoaded = false
    private let storageBase: URL
    private let apply: @MainActor ([DicdataElement]) -> Void

    init(storageBase: URL, apply: @escaping @MainActor ([DicdataElement]) -> Void) {
        self.storageBase = storageBase
        self.apply = apply
        CandidateBlocklist.shared.setLocalPatterns(HubUserDictionary.loadLocalBlock(base: storageBase))
    }

    /// azooKey 本来の動的辞書(OS ユーザ辞書・連絡先)を差し替える
    func setBaseEntries(_ entries: [DicdataElement]) {
        baseEntries = entries
        loadHubCacheIfNeeded()
        apply(baseEntries + hubEntries)
    }

    /// キャッシュを読み、必要ならネットから取り直す(フルアクセスが無いと通信できないので呼ばない)
    func refreshHub(hasFullAccess: Bool) {
        loadHubCacheIfNeeded()
        guard hasFullAccess else {
            return
        }
        HubUserDictionary.fetch(base: storageBase) { [weak self] payload in
            Task { @MainActor in
                self?.setHub(payload)
            }
        }
    }

    func addLocalBlock(_ text: String) {
        let list = HubUserDictionary.appending(text, to: HubUserDictionary.loadLocalBlock(base: storageBase))
        HubUserDictionary.saveLocalBlock(list, base: storageBase)
        CandidateBlocklist.shared.setLocalPatterns(list)
    }

    private func loadHubCacheIfNeeded() {
        guard !hubLoaded else {
            return
        }
        hubLoaded = true
        if let payload = HubUserDictionary.loadCache(base: storageBase) {
            hubEntries = HubUserDictionary.elements(payload)
            CandidateBlocklist.shared.setHubPatterns(payload.block ?? [])
        }
    }

    private func setHub(_ payload: HubUserDictionary.Payload) {
        hubEntries = HubUserDictionary.elements(payload)
        CandidateBlocklist.shared.setHubPatterns(payload.block ?? [])
        apply(baseEntries + hubEntries)
    }
}
