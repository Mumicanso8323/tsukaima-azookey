//
//  ZenzOutputGuard.swift
//  使い魔azooKey
//
//  変換候補の一覧から、zenz 由来の壊れた候補を取り除く。判定は ZenzOutputText で行う。
//  捨てた候補と、捨てる条件に近かった候補は、キーボードのパンくずに残す。本体アプリがそれを hub の device_log へ送る。
//  変換器は候補に由来の印を付けない。ただし、ユーザ辞書由来の候補には isFromUserDictionary の印が付く。
//  カオモジ辞書・ユーザ辞書・hub 辞書はその印で除外する。
//

import KanaKanjiConverterModule

public enum ZenzOutputGuard {
    /// 判定を残した候補 1 件分
    public struct Finding: Sendable, Equatable {
        public let judgement: ZenzOutputText.Judgement
        public let text: String
        public let reading: String
        /// `userdict`・`learned`・`dict-or-zenz` のどれか。変換器は zenz 由来に印を付けないので、辞書と zenz は区別できない
        public let source: String

        /// 同じ候補を何度も残さないための鍵。判定の種類と読みと候補から作る
        public var dedupeKey: String {
            "\(kindLabel)|\(reading)|\(text)"
        }

        /// 判定の種類の名前。パンくずの先頭に書く語
        public var kindLabel: String {
            switch judgement {
            case .keep: "keep"
            case .drop(let reason): "drop-\(reason.rawValue)"
            case .keepUserDictionary(let reason): "keep-userdict-\(reason.rawValue)"
            case .nearRepeat: "near-repeat-2"
            }
        }

        /// パンくずに残す 1 行。本文は候補と読みだけ、左文脈は文字数だけを書く
        public func breadcrumbLine(leftContextLength: Int, effort: String) -> String {
            "zenzguard \(kindLabel) src=\(source) reading=\(Self.plain(reading)) text=\(Self.plain(text)) left=\(leftContextLength) effort=\(effort)"
        }

        /// 空白と改行を `_` にして、1 行に収まる形にする
        static func plain(_ text: String) -> String {
            String(text.map { $0.isWhitespace || $0.isNewline ? "_" : $0 })
        }
    }

    /// 候補欄・ライブ変換に出す候補と、判定の記録
    public struct Screened {
        public let mainResults: [Candidate]
        public let firstClauseResults: [Candidate]
        public let findings: [Finding]
    }

    /// 2 つの候補一覧を判定し、捨てる候補を取り除く。捨てる条件に当たった候補・近かった候補は `findings` に残す。
    public static func screen(mainResults: [Candidate], firstClauseResults: [Candidate], reading: String) -> Screened {
        var findings: [Finding] = []
        func filterCandidates(_ candidates: [Candidate]) -> [Candidate] {
            var kept: [Candidate] = []
            for candidate in candidates {
                let source = source(of: candidate)
                let judgement = ZenzOutputText.judge(
                    text: candidate.text,
                    reading: reading,
                    isFromUserDictionary: source == "userdict"
                )
                switch judgement {
                case .keep:
                    kept.append(candidate)
                case .drop:
                    findings.append(Finding(judgement: judgement, text: candidate.text, reading: reading, source: source))
                case .keepUserDictionary, .nearRepeat:
                    kept.append(candidate)
                    findings.append(Finding(judgement: judgement, text: candidate.text, reading: reading, source: source))
                }
            }
            return kept
        }
        let main = filterCandidates(mainResults)
        let first = filterCandidates(firstClauseResults)
        return Screened(mainResults: main, firstClauseResults: first, findings: findings)
    }

    /// 候補の由来の大まかな区別。ユーザ辞書の印、学習の印の順に見る。どちらも無ければ辞書または zenz とする
    public static func source(of candidate: Candidate) -> String {
        if candidate.data.contains(where: { $0.metadata.contains(.isFromUserDictionary) }) {
            return "userdict"
        }
        if candidate.data.contains(where: { $0.metadata.contains(.isLearned) }) {
            return "learned"
        }
        return "dict-or-zenz"
    }
}
