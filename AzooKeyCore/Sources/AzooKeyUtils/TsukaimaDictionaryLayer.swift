import Foundation
import KanaKanjiConverterModule

/// 使い魔azooKey のカスタム辞書層(hub ユーザ辞書・定型文・同梱 TRPG 語彙)を、変換器に渡す
/// `DicdataElement` に落とすところ。キーボード拡張(HubUserDictionary)と本体アプリ内の
/// ハードウェアキーボード変換(HardwareIME)の両方がここを使い、同じ語が同じ重みで候補に出る。
///
/// 重み(value)の目安: azooKey の OS ユーザ辞書は -6〜-10、標準辞書の一般語はおおむね -8〜-20。
/// - hub の語(授業名・人名など): -5。短い読みでも確実に上に出したい固有名詞。
/// - 同梱 TRPG 語彙: -9。候補には出るが、日常語より上に割り込まない。
/// - 定型文(hint「定型文」): -14。読みを打っても本文が勝手に一番上(=ライブ変換・先頭候補)に
///   来ないよう、普通の語より弱くする。「候補の一つとして出るだけ」にするための値。
public enum TsukaimaDictionaryLayer {
    public static let hubValue: PValue = -5
    public static let trpgValue: PValue = -9
    public static let snippetValue: PValue = -14
    /// 定型文を表す hint(hub の bot/vocab.py `_ime_snippet_words` と揃える)
    public static let snippetHint = "定型文"
    /// 動的辞書は線形検索なので上限を設ける
    public static let maxWords = 20000

    /// hub の Payload を要素に落とす。空の語・読みは捨て、読みはカタカナに正規化する。
    public static func elements(_ payload: TsukaimaImeDict.Payload) -> [DicdataElement] {
        payload.words.prefix(maxWords).compactMap { element(word: $0.word, reading: $0.reading, hint: $0.hint, defaultValue: hubValue) }
    }

    /// 同梱の TRPG・クトゥルフ神話・ネクロニカ語彙(TsukaimaTrpgDict)
    public static func trpgElements() -> [DicdataElement] {
        TsukaimaTrpgDict.words.compactMap { element(word: $0.word, reading: $0.reading, hint: $0.hint, defaultValue: trpgValue) }
    }

    /// hub 辞書 + 同梱 TRPG 語彙。hub 側に同じ表記があれば hub の方(重みが強い)を残す。
    public static func combinedElements(hub payload: TsukaimaImeDict.Payload?) -> [DicdataElement] {
        let hub = payload.map(elements) ?? []
        let known = Set(hub.map { $0.word + "\t" + $0.ruby })
        return hub + trpgElements().filter { !known.contains($0.word + "\t" + $0.ruby) }
    }

    public static func element(word: String, reading: String, hint: String?, defaultValue: PValue) -> DicdataElement? {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruby = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
        guard !word.isEmpty, !ruby.isEmpty else {
            return nil
        }
        let value = value(hint: hint, defaultValue: defaultValue)
        return DicdataElement(word: word, ruby: ruby, cid: cid(hint), mid: mid(hint), value: value)
    }

    /// 定型文だけは「候補に出るが勝たない」重みにする
    public static func value(hint: String?, defaultValue: PValue) -> PValue {
        hint == snippetHint ? snippetValue : defaultValue
    }

    /// hint が品詞らしければ使う。それ以外は一般名詞扱い
    public static func cid(_ hint: String?) -> Int {
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

    public static func mid(_ hint: String?) -> Int {
        switch hint {
        case "姓": MIDData.人名姓.mid
        case "名": MIDData.人名名.mid
        case "組織": MIDData.組織.mid
        default: MIDData.一般.mid
        }
    }
}
