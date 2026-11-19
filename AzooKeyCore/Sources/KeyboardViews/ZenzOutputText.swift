//
//  ZenzOutputText.swift
//  使い魔azooKey
//
//  zenz の出力に由来する壊れた変換候補を、文字列だけから見分ける判定。変換器の型には依存しない。
//  2026-11-19 本人の報告: 読み「あか」の候補欄に「〔?ア〕〔?〕〔?〕〔?〕〔?〕か」が出た。
//  変換器は zenz 由来の候補に印を付けないため、判定は候補の文字と読みだけで行う。
//

import Foundation

public enum ZenzOutputText {
    /// 候補を捨てる理由
    public enum Reason: String, Sendable, Equatable {
        /// ASCII の `?` か U+FFFD を含み、読みに同じ文字が無い
        case brokenCharacter = "broken-char"
        /// 同じ2文字以上の並びが3回以上あり、読みより多い
        case repeatRun = "repeat"
    }

    /// 候補の判定
    public enum Judgement: Sendable, Equatable {
        /// 候補欄に出す
        case keep
        /// 候補欄に出さない
        case drop(Reason)
        /// 捨てる条件に当たるが、ユーザ辞書由来なので残す。診断用に記録する
        case keepUserDictionary(Reason)
        /// 反復が2回だけあり、捨てる条件の直前。診断用に記録する
        case nearRepeat
    }

    /// 反復とみなす回数。重ならない出現で数える
    public static let repeatThreshold = 3
    /// 反復の単位の長さの上限。計算量を抑えるため、これより長い単位は見ない
    static let maxRepeatUnitLength = 40

    /// 候補の判定。`isFromUserDictionary` が true なら、条件に当たっても捨てない
    public static func judge(text: String, reading: String, isFromUserDictionary: Bool) -> Judgement {
        let readingChars = Array(hiraganaNormalized(reading))
        let runs: [(count: Int, readingCount: Int)] = repeatedUnits(in: Array(hiraganaNormalized(text))).map {
            ($0.count, nonOverlappingCount(of: $0.unit, in: readingChars))
        }
        let reason: Reason?
        if hasBrokenCharacter(text: text, reading: reading) {
            reason = .brokenCharacter
        } else if runs.contains(where: { $0.count >= repeatThreshold && $0.count > $0.readingCount }) {
            reason = .repeatRun
        } else {
            reason = nil
        }
        if let reason {
            return isFromUserDictionary ? .keepUserDictionary(reason) : .drop(reason)
        }
        if !isFromUserDictionary, runs.contains(where: { $0.count == repeatThreshold - 1 && $0.count > $0.readingCount }) {
            return .nearRepeat
        }
        return .keep
    }

    /// 候補に ASCII の `?` か U+FFFD があり、読みに同じ文字が無い
    public static func hasBrokenCharacter(text: String, reading: String) -> Bool {
        let readingScalars = Set(reading.unicodeScalars)
        return text.unicodeScalars.contains { scalar in
            isBrokenScalar(scalar) && !readingScalars.contains(scalar)
        }
    }

    static func isBrokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x3F || scalar.value == 0xFFFD
    }

    /// 候補の中で、重ならない出現が2回以上ある2文字以上の並びと、その回数
    static func repeatedUnits(in chars: [Character]) -> [(unit: [Character], count: Int)] {
        let n = chars.count
        guard n >= 4 else { return [] }
        var result: [(unit: [Character], count: Int)] = []
        for length in 2...min(n / 2, maxRepeatUnitLength) {
            var overlapping: [[Character]: Int] = [:]
            for start in 0...(n - length) {
                overlapping[Array(chars[start..<(start + length)]), default: 0] += 1
            }
            for (unit, seen) in overlapping where seen >= 2 {
                let count = nonOverlappingCount(of: unit, in: chars)
                if count >= 2 {
                    result.append((unit: unit, count: count))
                }
            }
        }
        return result
    }

    /// `chars` の中で `unit` が重ならずに現れる回数
    static func nonOverlappingCount(of unit: [Character], in chars: [Character]) -> Int {
        let m = unit.count
        guard m > 0, chars.count >= m else { return 0 }
        var count = 0
        var i = 0
        while i + m <= chars.count {
            if chars[i..<(i + m)].elementsEqual(unit) {
                count += 1
                i += m
            } else {
                i += 1
            }
        }
        return count
    }

    /// 全角カタカナをひらがなにそろえる。カタカナとひらがなの違いで反復の数が変わらないようにする
    static func hiraganaNormalized(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if (0x30A1...0x30F6).contains(scalar.value), let hiragana = Unicode.Scalar(scalar.value - 0x60) {
                view.append(hiragana)
            } else {
                view.append(scalar)
            }
        }
        return String(view)
    }
}
