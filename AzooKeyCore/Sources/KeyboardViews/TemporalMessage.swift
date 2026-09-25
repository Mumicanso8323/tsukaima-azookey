//
//  TemporalMessage.swift
//
//
//  Created by ensan on 2023/07/22.
//

import struct SwiftUI.LocalizedStringKey

public enum TemporalMessage: Sendable {
    case doneForgetCandidate
    case doneBlockCandidate
    case doneReportWrongConversion
    case failedReportWrongConversion

    var title: LocalizedStringKey {
        switch self {
        case .doneForgetCandidate:
            return "候補の学習をリセットしました"
        case .doneBlockCandidate:
            return "この候補を今後出さないようにしました"
        case .doneReportWrongConversion:
            return "誤変換を報告しました"
        case .failedReportWrongConversion:
            return "誤変換の報告に失敗しました"
        }
    }

    public enum DismissCondition: Sendable {
        case auto
        case ok
    }

    var dismissCondition: DismissCondition {
        switch self {
        case .doneForgetCandidate, .doneBlockCandidate, .doneReportWrongConversion, .failedReportWrongConversion: return .auto
        }
    }
}
