//
//  InputManager.swift
//  Keyboard
//
//  Created by ensan on 2022/12/30.
//  Copyright © 2022 ensan. All rights reserved.
//

import AzooKeyUtils
import CustardKit
import KanaKanjiConverterModule
import KeyboardExtensionUtils
import KeyboardViews
import OrderedCollections
import SwiftUtils
import UIKit
final class InputManager {
    // 入力中の文字列を管理する構造体
    private(set) var composingText = ComposingText()
    // 表示される文字列を管理するクラス
    private(set) var displayedTextManager: DisplayedTextManager
    // TODO: displayedTextManagerとliveConversionManagerを何らかの形で統合したい
    // ライブ変換を管理するクラス
    var liveConversionManager: LiveConversionManager
    // (ゼロクエリの)予測変換を管理するクラス
    var predictionManager = PredictionManager()
    // セレクトされているか否か、現在入力中の文字全体がセレクトされているかどうかである。
    // TODO: isSelectedはdisplayedTextManagerが持っているべき
    var isSelected = false
    /// かな漢字変換を受け持つ変換器。
    @MainActor private lazy var kanaKanjiConverter = KanaKanjiConverter(dicdataStore: DicdataStore(dictionaryURL: Self.dictionaryResourceURL))

    init() {
        @KeyboardSetting(.liveConversion) var liveConversion
        @KeyboardSetting(.markedTextSetting) var markedTextSetting

        self.displayedTextManager = DisplayedTextManager(isLiveConversionEnabled: liveConversion, isMarkedTextEnabled: markedTextSetting != .disabled)
        self.liveConversionManager = LiveConversionManager(enabled: liveConversion)
    }
    // キーボードの言語
    private var keyboardLanguage: KeyboardLanguage = .ja_JP
    @MainActor func setKeyboardLanguage(_ value: KeyboardLanguage) {
        self.keyboardLanguage = value
        self.kanaKanjiConverter.setKeyboardLanguage(value)
    }

    /// システム側でproxyを操作した結果、`textDidChange`などがよばれてしまう場合に、その呼び出しをスキップするため、フラグを事前に立てる
    private var previousSystemOperation: SystemOperationType?
    enum SystemOperationType {
        case moveCursor
        case setMarkedText
        case removeSelection
    }

    // 再変換機能の提供のために用いる辞書
    private var rubyLog: OrderedDictionary<String, String> = [:]

    // 変換結果の通知用関数
    private var updateResult: (((inout ResultModel) -> Void) -> Void)?

    private var liveConversionEnabled: Bool {
        liveConversionManager.enabled && !self.isSelected
    }

    func getEnterKeyState() -> RoughEnterKeyState {
        if !self.isSelected && !self.composingText.isEmpty {
            return .complete
        } else {
            return .return
        }
    }

    @MainActor func getSurroundingText() -> (leftText: String, center: String, rightText: String) {
        let left = adjustLeftString(self.displayedTextManager.documentContextBeforeInput(ignoreComposition: true) ?? "")
        let center = self.displayedTextManager.selectedText ?? ""
        let right = self.displayedTextManager.documentContextAfterInput ?? ""

        return (left, center, right)
    }

    func getTextChangedCount() -> Int {
        self.displayedTextManager.getTextChangedCount()
    }

    func getComposingText() -> ComposingText {
        self.composingText
    }

    func getCandidate(for forms: [CharacterForm]) -> Candidate {
        var text = self.composingText.convertTarget
        for form in forms {
            switch form {
            case .hiragana:
                text = text.toHiragana()
            case .katakana:
                text = text.toKatakana()
            case .halfwidthKatakana:
                text = text.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            case .uppercase:
                text = text.uppercased()
            case .lowercase:
                text = text.lowercased()
            }
        }
        return .init(text: text, value: 0, composingCount: .surfaceCount(self.composingText.convertTargetCursorPosition), lastMid: MIDData.一般.mid, data: [])
    }

    private static let dictionaryResourceURL = Bundle.main.bundleURL.appendingPathComponent("Dictionary", isDirectory: true)
    private static let memoryDirectoryURL = (try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)) ?? sharedContainerURL
    private static let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupKey)!
    private static let zenzSmallWeightURL = Bundle.main.bundleURL.appendingPathComponent("zenz-v3.1-small-gguf/ggml-model-Q5_K_M.gguf", isDirectory: false)
    private static let zenzXsmallWeightURL = Bundle.main.bundleURL.appendingPathComponent("zenz-v3.1-xsmall-gguf/ggml-model-Q5_K_M.gguf", isDirectory: false)

    @MainActor private func getConvertRequestOptions(inputStylePreference: InputStyle? = nil) -> ConvertRequestOptions {
        let requireJapanesePrediction: Bool
        let requireEnglishPrediction: Bool
        switch (isSelected, inputStylePreference ?? .direct) {
        case (true, _):
            requireJapanesePrediction = false
            requireEnglishPrediction = false
        case (false, .direct):
            requireJapanesePrediction = true
            requireEnglishPrediction = true
        case (false, .roman2kana):
            requireJapanesePrediction = keyboardLanguage == .ja_JP
            requireEnglishPrediction = keyboardLanguage == .en_US
        case (false, .mapped):
            requireJapanesePrediction = keyboardLanguage == .ja_JP
            requireEnglishPrediction = false
        }
        @KeyboardSetting(.typographyLetter) var typographyLetterCandidate
        @KeyboardSetting(.englishCandidate) var englishCandidateInRoman2KanaInput
        @KeyboardSetting(.learningType) var learningType

        var providers: [any SpecialCandidateProvider] = [.calendar, .commaSeparatedNumber, .emailAddress, .timeExpression, .unicode, .version]
        if typographyLetterCandidate {
            providers.append(.typography)
        }

        let zenzaiMode: ConvertRequestOptions.ZenzaiMode
        @KeyboardSetting(.zenzaiEnable) var zenzaiToggle
        if zenzaiToggle {
            @KeyboardSetting(.zenzaiEffort) var effort
            let (inferenceLimit, weightURL): (Int, URL) = switch effort {
            case .high: (3, Self.zenzSmallWeightURL)
            case .medium: (1, Self.zenzSmallWeightURL)
            case .low: (2, Self.zenzXsmallWeightURL)
            }
            zenzaiMode = .on(
                weight: weightURL,
                inferenceLimit: inferenceLimit,
                personalizationMode: nil,
                versionDependentMode: .v3(.init(leftSideContext: self.getSurroundingText().leftText, maxLeftSideContextLength: 20))
            )
        } else {
            zenzaiMode = .off
        }

        return ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: keyboardLanguage,
            // KeyboardSettingsを注入
            englishCandidateInRoman2KanaInput: englishCandidateInRoman2KanaInput,
            fullWidthRomanCandidate: true,
            halfWidthKanaCandidate: true,
            learningType: learningType,
            maxMemoryCount: 65536,
            shouldResetMemory: MemoryResetCondition.shouldReset(),
            memoryDirectoryURL: Self.memoryDirectoryURL,
            sharedContainerURL: Self.sharedContainerURL,
            textReplacer: self.textReplacer,
            specialCandidateProviders: providers,
            zenzaiMode: zenzaiMode,
            metadata: .init(versionString: "azooKey version " + (SharedStore.currentAppVersion?.description ?? "Unknown")))
    }

    @MainActor private func getConvertRequestOptionsForPrediction() -> (ConvertRequestOptions, denylist: Set<String>) {
        // 絵文字変換が無効になっている場合、予測変換からも絵文字を抜く
        var options = getConvertRequestOptions()
        @KeyboardSetting(.additionalSystemDictionarySetting) var additionalSystemDictionarySetting
        if additionalSystemDictionarySetting.systemDictionarySettings[.emoji]?.enabled == false {
            options.textReplacer = .empty
        }
        return (options, additionalSystemDictionarySetting.systemDictionarySettings[.emoji]?.denylist ?? [])
    }

    private func updateLog(candidate: Candidate) {
        for data in candidate.data {
            // 「感謝する: カンシャスル」→を「感謝: カンシャ」に置き換える
            var word = data.word.toHiragana()
            var ruby = data.ruby.toHiragana()

            // wordのlastがrubyのlastである時、この文字は仮名なので
            while !word.isEmpty && word.last == ruby.last {
                word.removeLast()
                ruby.removeLast()
            }
            while !word.isEmpty && word.first == ruby.first {
                word.removeFirst()
                ruby.removeFirst()
            }
            if word.isEmpty {
                continue
            }
            // 一度消してから入れる(reorder)
            rubyLog.removeValue(forKey: word)
            rubyLog[word] = ruby
        }
        while rubyLog.count > 100 {  // 最大100個までログを取る
            rubyLog.removeFirst()
        }
        debug("rubyLog", rubyLog)
    }

    /// ルビ(ひらがな)を返す
    private func getRubyIfPossible(text: String) -> String? {
        // TODO: もう少しやりようがありそう、例えばログを見てひたすら置換し、最後にkanaだったらヨシ、とか？
        // ユーザがテキストを選択した場合、というやや強い条件が入っているので、パフォーマンスをあまり気にしなくても大丈夫
        // 長い文章を再変換しない、みたいな仮定も入れられる
        if let ruby = rubyLog[text] {
            return ruby.toHiragana()
        }
        // 長い文章は諦めてもらう
        if text.count > 20 {
            return nil
        }
        // {hiragana}*{known word}のパターンを救う
        do {
            for (word, ruby) in rubyLog where text.hasSuffix(word) {
                if text.dropLast(word.count).isKana {
                    return (text.dropLast(word.count) + ruby).toHiragana()
                }
            }
        }
        // {known word}{hiragana}*のパターンを救う
        do {
            for (word, ruby) in rubyLog where text.hasPrefix(word) {
                if text.dropFirst(word.count).isKana {
                    return (ruby + text.dropFirst(word.count)).toHiragana()
                }
            }
        }
        return nil
    }
    /// 置換機
    private var textReplacer = TextReplacer(emojiDataProvider: {
        // 読み込むファイルはバージョンごとに変更する必要がある
        if #available(iOS 18.4, *) {
            Bundle.main.bundleURL.appendingPathComponent("emoji_all_E16.0.txt", isDirectory: false)
        } else {
            // in this case, always satisfies #available(iOS 17.4, *)
            Bundle.main.bundleURL.appendingPathComponent("emoji_all_E15.1.txt", isDirectory: false)
        }
    })

    func setTextDocumentProxy(_ proxy: AnyTextDocumentProxy) {
        self.displayedTextManager.setTextDocumentProxy(proxy)
    }

    func setUpdateResult(_ updateResult: (((inout ResultModel) -> Void) -> Void)?) {
        self.updateResult = updateResult
    }

    func getPreviousSystemOperation() -> SystemOperationType? {
        if let previousSystemOperation {
            self.previousSystemOperation = nil
            return previousSystemOperation
        }
        return nil
    }

    /// 結果の更新
    func updateTextReplacementCandidates(left: String, center: String, right: String, target: [ConverterBehaviorSemantics.ReplacementTarget]) {
        let results = self.textReplacer.getReplacementCandidate(left: left, center: center, right: right, target: target)
        if let updateResult {
            updateResult {
                $0.setResults(results)
            }
        }
    }

    /// 検索結果の更新
    func getSearchResult(query: String, target: [ConverterBehaviorSemantics.ReplacementTarget]) -> [any ResultViewItemData] {
        let results = self.textReplacer.getSearchResult(query: query, target: target)
        return results
    }

    /// 絵文字候補のクリーニング
    @MainActor func cleaningEmojiPredictionCandidates(candidates: consuming [PostCompositionPredictionCandidate], denylist: Set<String>) -> [PostCompositionPredictionCandidate] {
        candidates.filter {
            // variation selectorを外す
            let normalized = String($0.text.unicodeScalars.filter { $0.value != 0xFE0F })
            // 1文字でもdenylistに含まれるものがあったらエラー
            return normalized.allSatisfy({!denylist.contains(String($0))})
        }

    }

    /// 確定直後に呼ぶ
    @MainActor func updatePostCompositionPredictionCandidates(candidate: Candidate) {
        let (options, denylist) = getConvertRequestOptionsForPrediction()
        var results = self.kanaKanjiConverter.requestPostCompositionPredictionCandidates(leftSideCandidate: candidate, options: options)
        results = self.cleaningEmojiPredictionCandidates(candidates: results, denylist: denylist)
        predictionManager.updateAfterComplete(candidate: candidate, textChangedCount: self.displayedTextManager.getTextChangedCount())
        if let updateResult {
            updateResult {
                $0.setPredictionResults(results)
            }
        }
    }

    /// 予測変換を選んだ後に呼ぶ
    @MainActor func postCompositionPredictionCandidateSelected(candidate: PostCompositionPredictionCandidate) {
        guard let lastUsedCandidate = predictionManager.getLastCandidate() else {
            return
        }
        self.kanaKanjiConverter.updateLearningData(lastUsedCandidate, with: candidate)
        let newCandidate = candidate.join(to: lastUsedCandidate)

        // 絵文字変換が無効になっている場合、予測変換からも絵文字を抜く
        let (options, denylist) = getConvertRequestOptionsForPrediction()
        var results = self.kanaKanjiConverter.requestPostCompositionPredictionCandidates(leftSideCandidate: newCandidate, options: options)
        results = self.cleaningEmojiPredictionCandidates(candidates: results, denylist: denylist)
        predictionManager.update(candidate: newCandidate, textChangedCount: self.displayedTextManager.getTextChangedCount())
        if let updateResult {
            updateResult {
                $0.setPredictionResults(results)
            }
        }
    }

    func resetPostCompositionPredictionCandidates() {
        if let updateResult {
            updateResult {
                $0.setPredictionResults([])
            }
        }
    }

    func resetPostCompositionPredictionCandidatesIfNecessary(textChangedCount: Int) {
        if predictionManager.shouldResetPrediction(textChangedCount: textChangedCount) {
            self.resetPostCompositionPredictionCandidates()
        }
    }

    /// `composingText`に入力されていた全体が変換された後に呼ばれる関数
    @MainActor private func conversionCompleted(candidate: Candidate) {
        // 予測変換を更新する
        self.updatePostCompositionPredictionCandidates(candidate: candidate)
    }

    /// 変換を選択した場合に呼ばれる
    @MainActor func complete(candidate: Candidate) {
        self.updateLog(candidate: candidate)
        self.composingText.prefixComplete(composingCount: candidate.composingCount)
        if self.displayedTextManager.shouldSkipMarkedTextChange {
            self.previousSystemOperation = .setMarkedText
        }
        self.displayedTextManager.updateComposingText(composingText: self.composingText, completedPrefix: candidate.text, isSelected: self.isSelected)
        self.kanaKanjiConverter.updateLearningData(candidate)
        guard !self.composingText.isEmpty else {
            // ここで入力を停止する
            self.stopComposition()
            self.conversionCompleted(candidate: candidate)
            return
        }
        self.isSelected = false
        self.kanaKanjiConverter.setCompletedData(candidate)

        if liveConversionEnabled {
            self.liveConversionManager.updateAfterFirstClauseCompletion()
        }
        self.setResult()
    }

    /// 入力を停止する。DisplayedTextには特に何もしない。
    @MainActor func stopComposition() {
        self.composingText.stopComposition()
        self.displayedTextManager.stopComposition()
        self.liveConversionManager.stopComposition()
        self.kanaKanjiConverter.stopComposition()

        self.isSelected = false

        if let updateResult {
            updateResult {
                $0.setResults([])
            }
        }

        @KeyboardSetting(.liveConversion) var liveConversion
        @KeyboardSetting(.markedTextSetting) var markedTextSetting

        self.displayedTextManager.updateSettings(isLiveConversionEnabled: liveConversion, isMarkedTextEnabled: markedTextSetting != .disabled)
    }

    @MainActor func closeKeyboard() {
        debug("closeKeyboard: キーボードが閉じます")
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.kanaKanjiConverter.updateUserDictionaryURL(Self.sharedContainerURL, forceReload: true)
        self.displayedTextManager.closeKeyboard()
        _ = self.enter()
    }

    /// 「現在入力中として表示されている文字列で確定する」というセマンティクスを持った操作である。
    /// - parameters:
    ///  - shouldModifyDisplayedText: DisplayedTextを操作して良いか否か。`textDidChange`などの場合は操作してはいけない。
    @MainActor func enter(shouldModifyDisplayedText: Bool = true, requireSetResult: Bool = true) -> [ActionType] {
        // selectedの場合、単に変換を止める
        if isSelected {
            self.stopComposition()
            return []
        }
        if self.composingText.isEmpty {
            return []
        }
        var candidate: Candidate
        if liveConversionEnabled, let _candidate = liveConversionManager.lastUsedCandidate {
            candidate = _candidate
        } else {
            let composingText = self.composingText.prefixToCursorPosition()
            candidate = Candidate(
                text: composingText.convertTarget,
                value: -18,
                composingCount: .inputCount(composingText.input.count),
                lastMid: MIDData.一般.mid,
                data: [
                    DicdataElement(
                        word: composingText.convertTarget,
                        ruby: composingText.convertTarget.toKatakana(),
                        cid: CIDData.固有名詞.cid,
                        mid: MIDData.一般.mid,
                        value: -18
                    ),
                ]
            )
        }
        let actions = self.kanaKanjiConverter.getAppropriateActions(candidate)
        candidate.withActions(actions)
        candidate.parseTemplate()
        self.updateLog(candidate: candidate)
        if shouldModifyDisplayedText {
            self.composingText.prefixComplete(composingCount: candidate.composingCount)
            if self.displayedTextManager.shouldSkipMarkedTextChange {
                self.previousSystemOperation = .setMarkedText
            }
            self.displayedTextManager.updateComposingText(composingText: self.composingText, completedPrefix: candidate.text, isSelected: self.isSelected)
        }
        if self.displayedTextManager.composingText.isEmpty {
            self.stopComposition()
            self.conversionCompleted(candidate: candidate)
        } else if requireSetResult {
            self.setResult()
        }
        return actions.map(\.action)
    }

    @MainActor func insertMainDisplayText(_ text: String) {
        self.displayedTextManager.insertMainDisplayText(text)
    }

    @MainActor func deleteSelection() {
        // 選択部分を削除する
        self.previousSystemOperation = .removeSelection
        self.displayedTextManager.deleteBackward(count: 1)
        // 状態をリセットする
        self.composingText.stopComposition()
        self.kanaKanjiConverter.stopComposition()
        self.isSelected = false
    }

    /// テキスト入力を扱う関数
    /// - Parameters:
    ///   - text: 入力される関数
    ///   - requireSetResult: `View`のアップデートを、この呼び出しで実施するべきか。この後さらに別の呼び出しを行う場合は、`false`にする。
    ///   - simpleInsert: `ComposingText`を作るのではなく、直接文字を入力し、変換候補を表示しない。
    ///   - inputStyle: 入力スタイル
    @MainActor func input(text: String, requireSetResult: Bool = true, simpleInsert: Bool = false, inputStyle: InputStyle) {
        // 直接入力の条件
        if simpleInsert         // flag
            || text == "\n"     // 改行
            || text == " " || text == "　" || text == "\t" || text == "\0" // スペース類
            || self.keyboardLanguage == .none { // 言語がnone
            // 必要に応じて確定する
            if !self.isSelected {
                _ = self.enter()
            } else {
                self.stopComposition()
            }
            self.displayedTextManager.insertText(text)
            return
        }
        // 直接入力にならない場合はまず選択部分を削除する
        if self.isSelected {
            // 選択部分を削除する
            self.deleteSelection()
        }
        self.composingText.insertAtCursorPosition(text, inputStyle: inputStyle)
        debug("Input Manager input:", composingText)
        if requireSetResult {
            // 変換を実施する
            self.setResult()
        }
    }

    /// テキストの進行方向に削除する
    /// `ab|c → ab|`のイメージ
    @MainActor func deleteForward(count: Int, requireSetResult: Bool = true) {
        if count < 0 {
            return
        }

        guard !self.composingText.isEmpty else {
            self.displayedTextManager.deleteForward(count: count)
            return
        }

        self.composingText.deleteForwardFromCursorPosition(count: count)
        debug("Input Manager deleteForward: ", composingText)

        if requireSetResult {
            // 変換を実施する
            self.setResult()
        }
    }

    /// テキストの進行方向と逆に削除する
    /// `ab|c → a|c`のイメージ
    /// - Parameters:
    ///   - convertTargetCount: `convertTarget`の文字数。`displayedText`の文字数ではない。
    ///   - requireSetResult: `setResult()`の呼び出しを要求するか。
    @MainActor func deleteBackward(convertTargetCount: Int, requireSetResult: Bool = true) {
        if convertTargetCount == 0 {
            return
        }
        // 選択状態ではオール削除になる
        if self.isSelected {
            // 選択部分を削除する
            self.displayedTextManager.deleteBackward(count: 1)
            // 変換をリセットする
            self.stopComposition()
            return
        }
        // 条件
        if convertTargetCount < 0 {
            self.deleteForward(count: abs(convertTargetCount), requireSetResult: requireSetResult)
            return
        }
        guard !self.composingText.isEmpty else {
            self.displayedTextManager.deleteBackward(count: convertTargetCount)
            return
        }

        self.composingText.deleteBackwardFromCursorPosition(count: convertTargetCount)
        debug("Input Manager deleteBackword: ", composingText)

        if requireSetResult {
            // 変換を実施する
            self.setResult()
        }
    }

    /// 特定の文字まで削除する
    ///  - returns: 削除した文字列
    @MainActor func smoothDelete(to nexts: [Character] = ["、", "。", "！", "？", ".", ",", "．", "，", "\n"], requireSetResult: Bool = true) -> String {
        // 選択状態ではオール削除になる
        if self.isSelected {
            let targetText = self.composingText.convertTarget
            // 選択部分を完全に削除する
            self.displayedTextManager.deleteBackward(count: 1)
            // Compositionをリセットする
            self.stopComposition()
            return targetText
        }
        // 入力中の場合
        if !self.composingText.isEmpty {
            // この実装は、ライブ変換時はカーソルより右に文字列が存在しないことが保証されているために有効になっている。
            let targetText = self.displayedTextManager.displayedLiveConversionText ?? String(self.composingText.convertTargetBeforeCursor)
            // カーソルより前を全部消す
            self.composingText.deleteBackwardFromCursorPosition(count: self.composingText.convertTargetCursorPosition)
            // 文字がもうなかった場合、ここで全て削除して終了
            if self.composingText.isEmpty {
                // 全て削除する
                if self.displayedTextManager.shouldSkipMarkedTextChange {
                    self.previousSystemOperation = .setMarkedText
                }
                self.displayedTextManager.updateComposingText(composingText: self.composingText, newLiveConversionText: nil)
                self.stopComposition()
                return targetText
            }
            // カーソルを先頭に移動する
            self.moveCursor(count: self.composingText.convertTarget.count)
            if requireSetResult {
                setResult()
            }
            return targetText
        }

        var deletedCount = 0
        var targetText = ""
        while let last = self.displayedTextManager.documentContextBeforeInput()?.last {
            if nexts.contains(last) {
                break
            } else {
                targetText.insert(last, at: targetText.startIndex)
                self.displayedTextManager.deleteBackward(count: 1)
                deletedCount += 1
            }
        }
        if deletedCount == 0 {
            if let last = self.displayedTextManager.documentContextBeforeInput()?.last {
                targetText.insert(last, at: targetText.startIndex)
            }
            self.displayedTextManager.deleteBackward(count: 1)
        }
        return targetText
    }

    /// テキストの進行方向に、特定の文字まで削除する
    /// 入力中はカーソルから右側を全部消す
    @MainActor func smoothDeleteForward(to nexts: [Character] = ["、", "。", "！", "？", ".", ",", "．", "，", "\n"], requireSetResult: Bool = true) -> String {
        // 選択状態ではオール削除になる
        if self.isSelected {
            let targetText = self.composingText.convertTarget
            // 完全に削除する
            self.displayedTextManager.deleteBackward(count: 1)
            // Compositionをリセットする
            self.stopComposition()
            return targetText
        }
        // 入力中の場合
        if !self.composingText.isEmpty {
            // TODO: Check implementation of `requireSetResult`
            // count文字消せるのは自明なので、返り値は無視できる
            let targetText = self.composingText.convertTarget.suffix(self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            self.composingText.deleteForwardFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            // 文字がもうなかった場合
            if self.composingText.isEmpty {
                // 全て削除する
                if self.displayedTextManager.shouldSkipMarkedTextChange {
                    self.previousSystemOperation = .setMarkedText
                }
                self.displayedTextManager.updateComposingText(composingText: self.composingText, newLiveConversionText: nil)
                self.stopComposition()
            }
            // setResultを呼ばない(カーソル右側の文字列は変換対象にならないため)
            return String(targetText)
        }

        var deletedCount = 0
        var targetText = ""
        while let first = self.displayedTextManager.documentContextAfterInput?.first {
            if nexts.contains(first) {
                break
            } else {
                self.displayedTextManager.deleteForward(count: 1)
                targetText.append(first)
                deletedCount += 1
            }
        }
        if deletedCount == 0 {
            if let first = self.displayedTextManager.documentContextAfterInput?.first {
                targetText.append(first)
            }
            self.displayedTextManager.deleteForward(count: 1)
        }
        return targetText
    }

    /// テキストの進行方向と逆に、特定の文字までカーソルを動かす
    @MainActor func smartMoveCursorBackward(to nexts: [Character] = ["、", "。", "！", "？", ".", ",", "．", "，", "\n"], requireSetResult: Bool = true) {
        // 選択状態では左にカーソルを移動
        if isSelected {
            // 左にカーソルを動かす
            self.displayedTextManager.moveCursor(count: -1)
            self.stopComposition()
            return
        }
        // 入力中の場合
        if !composingText.isEmpty {
            if self.liveConversionEnabled {
                _ = self.enter()
                return
            }
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition)
            if requireSetResult {
                self.setResult()
            }
            return
        }

        var movedCount = 0
        while let last = displayedTextManager.documentContextBeforeInput()?.last {
            if nexts.contains(last) {
                break
            } else {
                self.displayedTextManager.moveCursor(count: -1)
                movedCount += 1
            }
        }
        if movedCount == 0 {
            self.displayedTextManager.moveCursor(count: -1)
        }
    }

    /// テキストの進行方向に、特定の文字までカーソルを動かす
    @MainActor func smartMoveCursorForward(to nexts: [Character] = ["、", "。", "！", "？", ".", ",", "．", "，", "\n"], requireSetResult: Bool = true) {
        // 選択状態では最も右にカーソルを移動
        if isSelected {
            self.displayedTextManager.moveCursor(count: 1)
            self.stopComposition()
            return
        }
        // 入力中の場合
        if !composingText.isEmpty {
            if self.liveConversionEnabled {
                _ = self.enter()
                return
            }
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            if requireSetResult {
                setResult()
            }
            return
        }

        var movedCount = 0
        while let first = displayedTextManager.documentContextAfterInput?.first {
            if nexts.contains(first) {
                break
            } else {
                self.displayedTextManager.moveCursor(count: 1)
                movedCount += 1
            }
        }
        if movedCount == 0 {
            self.displayedTextManager.moveCursor(count: 1)
        }
    }

    /// iOS16以上の仕様変更に対応するため追加されたAPI
    func adjustLeftString(_ left: String) -> String {
        var newLeft = left.components(separatedBy: "\n").last ?? ""
        if left.contains("\n") && newLeft.isEmpty {
            newLeft = "\n"
        }
        return newLeft
    }

    /// クリップボードの文字列をペーストする
    @MainActor func paste() {
        guard let text = UIPasteboard.general.string else {
            return
        }
        guard !text.isEmpty else {
            return
        }
        if isSelected {
            // 選択部分を削除する
            self.deleteSelection()
        }
        self.input(text: text, simpleInsert: true, inputStyle: .direct)
    }

    /// 文字のreplaceを実施する
    /// `changeCharacter`を`CustardKit`で扱うためのAPI。
    /// キーボード経由でのみ実行される。
    @MainActor func replaceLastCharacters(table: [String: String], requireSetResult: Bool = true, inputStyle: InputStyle) {
        debug(table, composingText, isSelected)
        if isSelected {
            if let replace = table[self.composingText.convertTarget] {
                // 選択部分を削除する
                self.deleteSelection()
                // 入力を実行する
                self.input(text: replace, simpleInsert: true, inputStyle: .direct)
            }
            return
        }
        let counts: (max: Int, min: Int) = table.keys.reduce(into: (max: 0, min: .max)) {
            $0.max = max($0.max, $1.count)
            $0.min = min($0.min, $1.count)
        }
        // 入力状態の場合、入力中のテキストの範囲でreplaceを実施する。
        if !composingText.isEmpty {
            let leftside = composingText.convertTargetBeforeCursor
            var found = false
            for count in (counts.min...counts.max).reversed() where count <= composingText.convertTargetCursorPosition {
                if let replace = table[String(leftside.suffix(count))] {
                    // deleteとinputを効率的に行うため、setResultを要求しない (変換を行わない)
                    self.deleteBackward(convertTargetCount: leftside.suffix(count).count, requireSetResult: false)
                    // ここで変換が行われる。内部的には差分管理システムによって「置換」の場合のキャッシュ変換が呼ばれる。
                    self.input(text: replace, requireSetResult: requireSetResult, inputStyle: inputStyle)
                    found = true
                    break
                }
            }
            if !found && requireSetResult {
                self.setResult()
            }
            return
        }
        // 言語の指定がない場合は、入力中のテキストの範囲でreplaceを実施する。
        if keyboardLanguage == .none {
            let leftside = displayedTextManager.documentContextBeforeInput() ?? ""
            for count in (counts.min...counts.max).reversed() where count <= leftside.count {
                if let replace = table[String(leftside.suffix(count))] {
                    self.displayedTextManager.deleteBackward(count: count)
                    self.displayedTextManager.insertText(replace)
                    break
                }
            }
        }
    }

    /// カーソル左側の1文字を変更する関数
    /// ひらがなの場合は小書き・濁点・半濁点化し、英字・ギリシャ文字・キリル文字の場合は大文字・小文字化する
    @MainActor func changeCharacter(behavior: ReplaceBehavior, requireSetResult: Bool = true, inputStyle: InputStyle) {
        if self.isSelected {
            return
        }
        guard let char = self.composingText.convertTargetBeforeCursor.last else {
            return
        }
        let changed = ReplaceBehaviorManager.apply(replaceBehavior: behavior, to: char)
        // 同じ文字の場合は無視する
        if Character(changed) == char {
            return
        }
        // deleteとinputを効率的に行うため、setResultを要求しない (変換を行わない)
        self.deleteBackward(convertTargetCount: 1, requireSetResult: false)
        // inputの内部でsetResultが発生する
        self.input(text: changed, requireSetResult: requireSetResult, inputStyle: inputStyle)
    }

    /// キーボード経由でのカーソル移動
    @MainActor func moveCursor(count: Int, requireSetResult: Bool = true) {
        if self.isSelected {
            // ただ横に動かす(選択解除)
            self.displayedTextManager.moveCursor(count: 1)
            // 解除する
            self.stopComposition()
            return
        }
        if count == 0 {
            return
        }
        // カーソルを移動した直後、挙動が不安定であるため、スキップを登録する
        self.previousSystemOperation = .moveCursor
        // 入力中の文字が空の場合は普通に動かす
        if composingText.isEmpty {
            self.displayedTextManager.moveCursor(count: count)
            return
        }
        if self.liveConversionEnabled {
            _ = self.enter()
            return
        }

        debug("Input Manager moveCursor:", composingText, count)

        _ = self.composingText.moveCursorFromCursorPosition(count: count)
        if count != 0 && requireSetResult {
            setResult()
        }
    }

    /// ユーザがキーボードを経由せずにカーソルを何かした場合の後処理を行う関数。
    ///  - note: この関数をユーティリティとして用いてはいけない。
    @MainActor func userMovedCursor(count: Int) -> [ActionType] {
        debug("userによるカーソル移動を検知、今の位置は\(composingText.convertTargetCursorPosition)、動かしたオフセットは\(count)")
        // 選択しているテキストがある場合はリザルトバーを表示する
        if self.isSelected {
            // リザルトバーを表示する
            return [.setCursorBar(.off), .setTabBar(.off)]
        }
        @KeyboardSetting(.displayCursorBarAutomatically) var displayCursorBarAutomatically
        // 入力テキストなし
        if self.composingText.isEmpty {
            return displayCursorBarAutomatically ? [.setCursorBar(.on)] : []
        }
        // ライブ変換有効
        if liveConversionEnabled {
            return displayCursorBarAutomatically ? [.setCursorBar(.on)] : []
        }
        let actualCount = composingText.moveCursorFromCursorPosition(count: count)
        self.previousSystemOperation = self.displayedTextManager.updateComposingText(composingText: self.composingText, userMovedCount: count, adjustedMovedCount: actualCount) ? .moveCursor : nil
        setResult()
        return [.setCursorBar(.off), .setTabBar(.off)]
    }

    /// ユーザが行を跨いでカーソルを動かした場合に利用する
    @MainActor func userJumpedCursor() -> [ActionType] {
        if self.composingText.isEmpty {
            @KeyboardSetting(.displayCursorBarAutomatically) var displayCursorBarAutomatically
            return displayCursorBarAutomatically ? [.setCursorBar(.on)] : []
        }
        self.stopComposition()
        return []
    }

    /// ユーザがキーボードを経由せずカットした場合の処理
    @MainActor func userCutText(text: String) {
        self.stopComposition()
    }

    @MainActor func forgetMemory(_ candidate: Candidate) {
        self.kanaKanjiConverter.forgetMemory(candidate)
    }

    @MainActor func importDynamicUserDictionary(_ userDictionary: [DicdataElement]) {
        self.kanaKanjiConverter.importDynamicUserDictionary(userDictionary)
    }

    // Reference: https://teratail.com/questions/57039?link=qa_related_pc
    func getReadingFromSystemAPI(_ text: String) -> String {
        let inputText = text as NSString
        let outputText = NSMutableString()

        // トークナイザ
        let tokenizer: CFStringTokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            inputText as CFString,
            CFRangeMake(0, inputText.length),
            kCFStringTokenizerUnitWordBoundary,
            CFLocaleCopyCurrent()
        )

        // 形態素解析した結果を順に得る
        var tokenType: CFStringTokenizerTokenType = CFStringTokenizerGoToTokenAtIndex(tokenizer, 0)
        while tokenType.rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let original = inputText.substring(with: NSRange(location: range.location, length: range.length))
            if original.isEnglishSentence {
                outputText.append(original)
            } else if let romaji = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? NSString {
                // ローマ字をまず得て、そのあとでカタカナにする
                let reading: NSMutableString = romaji.mutableCopy() as! NSMutableString  // swiftlint:disable:this force_cast
                CFStringTransform(reading as CFMutableString, nil, kCFStringTransformLatinKatakana, false)
                outputText.append(reading as String)
            } else {
                // タイ語の文字など扱えない文字が入ってくるとここに来うる
                outputText.append(original)
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return (outputText as String).toHiragana()
    }

    // ユーザが文章を選択した場合、その部分を入力中であるとみなす(再変換)
    @MainActor func userSelectedText(text: String, lengthLimit: Int) {
        self.composingText.stopComposition()
        // 文字がない場合
        if text.isEmpty
            // 文字数が多すぎる場合
            || text.count > lengthLimit
            // httpで始まる場合
            || text.hasPrefix("http")
            // 扱いにくい文字を含む場合
            || text.contains("\n") || text.contains("\r") || text.contains(" ") || text.contains("\t") {
            self.setResult()
            return
        }
        // 過去のログを見て、再変換に利用する
        let ruby = getReadingFromSystemAPI(self.getRubyIfPossible(text: text) ?? text)
        self.composingText.insertAtCursorPosition(ruby, inputStyle: .direct)

        self.isSelected = true
        self.setResult()
    }

    /// 選択を解除した場合、Compositionをリセットする
    @MainActor func userDeselectedText() {
        self.stopComposition()
    }

    /// 変換リクエストを送信し、結果をDisplayed Textにも反映する関数
    @MainActor func setResult() {
        let inputData = composingText.prefixToCursorPosition()
        debug("InputManager.setResult: value to be input", inputData)
        let options = self.getConvertRequestOptions(inputStylePreference: inputData.input.last?.inputStyle)
        debug("InputManager.setResult: options", options)
        let results = self.kanaKanjiConverter.requestCandidates(inputData, options: options)

        // 表示を更新する
        if !self.isSelected {
            if self.displayedTextManager.shouldSkipMarkedTextChange {
                self.previousSystemOperation = .setMarkedText
            }
            if liveConversionEnabled {
                let liveConversionText = self.liveConversionManager.updateWithNewResults(inputData, results.mainResults, firstClauseResults: results.firstClauseResults, convertTargetCursorPosition: inputData.convertTargetCursorPosition, convertTarget: inputData.convertTarget)
                self.displayedTextManager.updateComposingText(composingText: self.composingText, newLiveConversionText: liveConversionText)
            } else {
                self.displayedTextManager.updateComposingText(composingText: self.composingText, newLiveConversionText: nil)
            }
        }

        if let updateResult {
            let supplementaryItems: [any ResultViewItemData]
            if inputData.convertTarget == "えもじ" {
                supplementaryItems = Self.emojiSupplementaryCandidates.map { $0 as any ResultViewItemData }
            } else {
                let candidates: [Candidate] = {
                    var seenTexts = Set(results.mainResults.map(\.text))
                    var storage: [Candidate] = []
                    for candidate in results.firstClauseResults where candidate.inputable {
                        if seenTexts.insert(candidate.text).inserted {
                            storage.append(candidate)
                        }
                        if storage.count >= 2 {
                            break
                        }
                    }
                    return storage
                }()
                supplementaryItems = candidates.map { $0 as any ResultViewItemData }
            }

            updateResult { model in
                model.setResults(results.mainResults)
                if supplementaryItems.isEmpty {
                    model.resetSupplementaryCandidates()
                } else {
                    model.setSupplementaryCandidates(supplementaryItems)
                }
            }
            // 自動確定の実施
            if liveConversionEnabled, let firstClause = self.liveConversionManager.candidateForCompleteFirstClause() {
                debug("InputManager.setResult: Complete first clause", firstClause)
                self.complete(candidate: firstClause)
            }
        }
    }
}

private extension InputManager {
    static let emojiSupplementaryCandidates: [Candidate] = {
        let thumbsUp = Candidate(
            text: "👍",
            value: -1,
            composingCount: .surfaceCount(3),
            lastMid: MIDData.一般.mid,
            data: [
                DicdataElement(
                    word: "👍",
                    ruby: "えもじ",
                    cid: CIDData.記号.cid,
                    mid: MIDData.一般.mid,
                    value: -1
                )
            ],
            actions: [],
            inputable: true,
            isLearningTarget: false
        )
        let thumbsDown = Candidate(
            text: "👎",
            value: -1,
            composingCount: .surfaceCount(3),
            lastMid: MIDData.一般.mid,
            data: [
                DicdataElement(
                    word: "👎",
                    ruby: "えもじ",
                    cid: CIDData.記号.cid,
                    mid: MIDData.一般.mid,
                    value: -1
                )
            ],
            actions: [],
            inputable: true,
            isLearningTarget: false
        )
        return [thumbsUp, thumbsDown]
    }()
}

extension Candidate: @retroactive ResultViewItemData {
    #if DEBUG
    public func getDebugInformation() -> String {
        "Candidate(text: \(self.text), value: \(self.value), data: \(self.data.debugDescription))"
    }
    #endif
}

extension CompleteAction {
    var action: ActionType {
        switch self {
        case .moveCursor(let value):
            return .moveCursor(value)
        }
    }
}

extension ReplacementCandidate: @retroactive ResultViewItemData {}
extension TextReplacer.SearchResultItem: @retroactive ResultViewItemData {}

// TextReplacerがprintされると非常に長大なログが発生して支障があるため
extension TextReplacer: @retroactive CustomStringConvertible {
    public var description: String {
        "TextReplacer(emojiSearchDict: [...], emojiGroups: [...], nonBaseEmojis: [...])"
    }
}
