import Foundation
import AzooKeyUtils
import KanaKanjiConverterModule
import KeyboardViews

extension KeyboardActionManager {
    @MainActor
    func handleReportWrongConversion(
        _ candidate: any ResultViewItemData,
        index: Int?,
        variableStates: VariableStates
    ) async {
        await ReportSubmissionHelper.submitWrongConversion(
            candidate: candidate,
            index: index,
            variableStates: variableStates,
            inputManager: inputManager
        )
    }

    @MainActor
    func handlePrepareReportSuggestion(
        candidate: any ResultViewItemData,
        index: Int,
        variableStates: VariableStates
    ) {
        @KeyboardSetting(.enableWrongConversionReport) var reportEnabled
        guard reportEnabled else { return }
        guard SemiStaticStates.shared.hasFullAccess else { return }
        guard variableStates.isShowingPrimaryResults else { return }
        guard index != 0 else { return }
        guard let topCandidateData = variableStates.primaryResultCandidate(at: 0) else { return }
        guard let topCandidate = topCandidateData as? Candidate else { return }
        guard let selectedCandidate = candidate as? Candidate else { return }
        @KeyboardSetting(.wrongConversionReportFrequency) var frequency
        let denominator = frequency.probabilityDenominator
        if denominator > 1 && Int.random(in: 1...denominator) != 1 {
            return
        }

        let composingText = inputManager.getComposingText()
        let composingInputs = composingText.input
        let contextSnapshot = variableStates.surroundingText
        let leftContext = String(contextSnapshot.leftSideText.suffix(10))
        let rightContext = String(contextSnapshot.rightSideText.prefix(10))
        if selectedCandidate.rubyCount > composingText.convertTarget.count {
            return
        }
        let topSummary = CandidateSummary(
            displayText: topCandidate.text,
            rank: 0,
            rawCandidate: topCandidateData,
            composingInputs: composingInputs,
            candidateID: nil,
            composingCount: topCandidate.composingCount,
            leftContext: leftContext,
            rightContext: rightContext
        )
        let selectedSummary = CandidateSummary(
            displayText: selectedCandidate.text,
            rank: index,
            rawCandidate: candidate,
            composingInputs: composingInputs,
            candidateID: nil,
            composingCount: selectedCandidate.composingCount,
            leftContext: leftContext,
            rightContext: rightContext
        )
        guard variableStates.shouldPresentReportSuggestion(
            topDisplayText: topSummary.displayText,
            selectedDisplayText: selectedSummary.displayText,
            textChangedCount: variableStates.textChangedCount
        ) else { return }
        variableStates.registerReportSuggestionPresentation(
            topDisplayText: topSummary.displayText,
            selectedDisplayText: selectedSummary.displayText,
            textChangedCount: variableStates.textChangedCount
        )
        self.applyUpsideComponent(
            .reportSuggestion(.candidateRankingMismatch(top: topSummary, selected: selectedSummary)),
            variableStates: variableStates
        )
    }

    @MainActor
    func handleReportSuggestion(
        _ content: ReportContent,
        variableStates: VariableStates
    ) async -> Bool {
        @KeyboardSetting(.enableWrongConversionReport) var reportEnabled
        guard reportEnabled else {
            return false
        }
        return await ReportSubmissionHelper.submitSuggestion(
            content: content,
            variableStates: variableStates,
            inputManager: inputManager
        )
    }

    @MainActor
    func handlePresentReportDetail(
        _ content: ReportContent,
        variableStates: VariableStates
    ) {
        let entries = ReportSubmissionHelper.detailEntries(
            for: content,
            variableStates: variableStates,
            inputManager: inputManager
        )
        variableStates.reportDetailState = ReportDetailState(content: content, entries: entries)
    }

    @MainActor
    func handleDismissReportDetail(variableStates: VariableStates) {
        variableStates.reportDetailState = nil
    }
}
