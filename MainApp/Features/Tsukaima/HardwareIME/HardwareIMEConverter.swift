import AzooKeyUtils
import Foundation
import KanaKanjiConverterModule
import UIKit

/// 本体アプリ内のハードウェアキーボード変換の設定(UserDefaults.standard、本体アプリだけの設定)。
enum HardwareIMESettings {
    static let enabledKey = "tsukaima.hwime.enabled"

    /// 既定はオン。Bluetooth キーボードを繋いだときだけ動く(ソフトウェアキーボードの入力には触らない)。
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// azooKey の変換エンジン(KanaKanjiConverter)を本体アプリの中で動かし、HardwareIMECore に候補を渡す。
///
/// 辞書: 本体アプリのターゲットは辞書つきモジュール(KanaKanjiConverterModuleWithDefaultDictionary)を
/// リンクしていないので、同じ ipa に入っている Keyboard.appex の中の辞書バンドルを直接読む(ipa を
/// 二重に太らせない)。zenz の重みも同じく appex の中のものを使う。
/// ユーザ辞書(App Group)・hub 辞書・定型文・同梱 TRPG 語彙はキーボードと同じ層(TsukaimaDictionaryLayer)。
/// 学習: キーボード拡張の学習ファイルは拡張の private container にあって本体からは読めないため、
/// 本体側は Library/TsukaimaHardwareIME に別に育てる。
@MainActor
final class HardwareIMEConverter: HardwareIMEConversionProvider {
    static let shared = HardwareIMEConverter()

    let dictionaryURL: URL?
    private let zenzSmallURL: URL?
    private let zenzXsmallURL: URL?
    private var converter: KanaKanjiConverter?
    private var hubCacheModified: Date?? = .none
    private var blockPatterns: [String] = []
    private var flushTask: Task<Void, Never>?
    private var commitsSinceFlush = 0

    /// 辞書が見つかったか(見つからなければ設定画面で案内し、変換はしない)
    var isAvailable: Bool { dictionaryURL != nil }

    private init() {
        let roots = Self.resourceRoots()
        dictionaryURL = Self.locateDictionary(in: roots)
        zenzSmallURL = Self.locate("zenz-v3.2-small-gguf/ggml-model-Q5_K_M.gguf", in: roots)
        zenzXsmallURL = Self.locate("zenz-v3.2-xsmall-gguf/ggml-model-Q5_K_M.gguf", in: roots)
    }

    // MARK: - リソースの場所

    private static let memoryDirectoryURL: URL = {
        let base = (try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TsukaimaHardwareIME", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 探す順: 本体アプリのバンドル → 同梱の Keyboard.appex
    private static func resourceRoots() -> [URL] {
        var roots = [Bundle.main.bundleURL]
        if let plugins = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            roots += items.filter { $0.pathExtension == "appex" }
        }
        return roots
    }

    /// SwiftPM のリソースバンドル(<Package>_KanaKanjiConverterModuleWithDefaultDictionary.bundle)の中の Dictionary/
    static func locateDictionary(in roots: [URL]) -> URL? {
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for item in items where item.pathExtension == "bundle" && item.lastPathComponent.contains("KanaKanjiConverterModuleWithDefaultDictionary") {
                let dictionary = item.appendingPathComponent("Dictionary", isDirectory: true)
                if FileManager.default.fileExists(atPath: dictionary.appendingPathComponent("louds", isDirectory: true).path) {
                    return dictionary
                }
            }
        }
        return nil
    }

    private static func locate(_ relative: String, in roots: [URL]) -> URL? {
        roots.map { $0.appendingPathComponent(relative, isDirectory: false) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 変換器

    private func prepared() -> KanaKanjiConverter? {
        if let converter {
            refreshDynamicDictionaryIfChanged(converter)
            return converter
        }
        guard let dictionaryURL else {
            return nil
        }
        let converter = KanaKanjiConverter(dictionaryURL: dictionaryURL, preloadDictionary: false)
        converter.setKeyboardLanguage(.ja_JP)
        self.converter = converter
        refreshDynamicDictionaryIfChanged(converter, force: true)
        return converter
    }

    /// hub 辞書(本体アプリが App Group に書いたキャッシュ)+ 同梱 TRPG 語彙を動的辞書として渡す。
    /// mtime が変わったときだけ読み直す(HubUserDictionary と同じ考え方)。
    private func refreshDynamicDictionaryIfChanged(_ converter: KanaKanjiConverter, force: Bool = false) {
        let base = SharedStore.sharedContainerURL
        let url = TsukaimaImeDict.fileURL(base: base)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if !force, case .some(let previous) = hubCacheModified, previous == modified {
            return
        }
        hubCacheModified = .some(modified)
        let payload = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TsukaimaImeDict.Payload.self, from: $0) }
        converter.importDynamicUserDictionary(TsukaimaDictionaryLayer.combinedElements(hub: payload))
        let localBlockURL = base.appendingPathComponent("tsukaima", isDirectory: true).appendingPathComponent("block.json")
        let localBlock = (try? Data(contentsOf: localBlockURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        blockPatterns = ((payload?.block ?? []) + localBlock)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func options(leftContext: String) -> ConvertRequestOptions {
        @KeyboardSetting(.learningType) var learningType
        @KeyboardSetting(.englishCandidate) var englishCandidate
        @KeyboardSetting(.zenzaiEnable) var zenzaiEnable
        let zenzaiMode: ConvertRequestOptions.ZenzaiMode
        if zenzaiEnable {
            @KeyboardSetting(.zenzaiEffort) var effort
            let (inferenceLimit, weight): (Int, URL?) = switch effort {
            case .high: (3, zenzSmallURL)
            case .medium: (1, zenzSmallURL)
            case .low: (2, zenzXsmallURL)
            }
            if let weight {
                zenzaiMode = .on(
                    weight: weight,
                    inferenceLimit: inferenceLimit,
                    personalizationMode: nil,
                    versionDependentMode: .v3(.init(leftSideContext: leftContext, maxLeftSideContextLength: 20))
                )
            } else {
                zenzaiMode = .off
            }
        } else {
            zenzaiMode = .off
        }
        return ConvertRequestOptions(
            N_best: 12,
            // Hardware IME の Space は先頭候補を選ぶ操作なので、予測候補を混ぜない。
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: englishCandidate,
            fullWidthRomanCandidate: true,
            halfWidthKanaCandidate: true,
            learningType: learningType,
            maxMemoryCount: 65536,
            shouldResetMemory: false,
            memoryDirectoryURL: Self.memoryDirectoryURL,
            sharedContainerURL: SharedStore.sharedContainerURL,
            textReplacer: .empty,
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: zenzaiMode,
            metadata: .init(versionString: "tsukaima hardware IME " + (SharedStore.currentAppVersion?.description ?? "Unknown"))
        )
    }

    // MARK: - HardwareIMEConversionProvider

    func candidates(for composing: ComposingText, leftContext: String) -> [Candidate] {
        guard let converter = prepared() else {
            return []
        }
        let requestOptions = options(leftContext: leftContext)
        let candidates: [Candidate]
        if requestOptions.englishCandidateInRoman2KanaInput || requestOptions.fullWidthRomanCandidate || requestOptions.halfWidthKanaCandidate {
            // These are useful alternatives, but `HardwareIMECore` selects index 0 on the first
            // Space. Ask once without them, then append only the additional results so Space
            // never chooses English/full-width/half-width output ahead of a normal conversion.
            var primaryOptions = requestOptions
            primaryOptions.englishCandidateInRoman2KanaInput = false
            primaryOptions.fullWidthRomanCandidate = false
            primaryOptions.halfWidthKanaCandidate = false
            let primary = converter.requestCandidates(composing, options: primaryOptions).mainResults
            let primaryTexts = Set(primary.map(\.text))
            let expanded = converter.requestCandidates(composing, options: requestOptions).mainResults
            candidates = primary + expanded.filter { !primaryTexts.contains($0.text) }
        } else {
            candidates = converter.requestCandidates(composing, options: requestOptions).mainResults
        }
        return candidates.filter { candidate in
            !blockPatterns.contains { candidate.text.contains($0) }
        }
    }

    func didComplete(_ candidate: Candidate, compositionEnded: Bool) {
        guard let converter else {
            return
        }
        converter.updateLearningData(candidate)
        if compositionEnded {
            converter.stopComposition()
            commitsSinceFlush += 1
            scheduleFlush()
        } else {
            converter.setCompletedData(candidate)
        }
    }

    func didCancel() {
        converter?.stopComposition()
    }

    /// 学習を書き出す(確定が続く間はまとめて、少し静かになってから)
    private func scheduleFlush() {
        flushTask?.cancel()
        if commitsSinceFlush >= 20 {
            flushLearning()
            return
        }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.flushLearning()
        }
    }

    /// フォーカスを失う・背面に回るときに呼ぶ
    func flushLearning() {
        flushTask?.cancel()
        flushTask = nil
        guard commitsSinceFlush > 0, let converter else {
            return
        }
        commitsSinceFlush = 0
        converter.commitUpdateLearningData()
    }
}
