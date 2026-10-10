import AzooKeyUtils
import SwiftUI

@MainActor
final class OnboardingState: ObservableObject {
    @Published private(set) var isKeyboardActivated: Bool
    @Published var isPresented: Bool

    var resumeProgress: EnableAzooKeyViewProgress? {
        if isKeyboardActivated, !tutorialFinishedSuccessfully {
            return .setting
        }
        return nil
    }

    init() {
        let isKeyboardActivated = SharedStore.checkKeyboardActivation()
        self.isKeyboardActivated = isKeyboardActivated
        // 使い魔統合版では、キーボードを使わない人もアプリ(録音・目覚まし等)を使う。起動のたびに
        // 全画面の「キーボードを追加して」で塞がないよう、自動では出さない(使い方タブの案内から開ける)。
        self.isPresented = false
    }

    func present() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    func presentInterruptedTutorialIfNeeded() {
        if isKeyboardActivated, !tutorialFinishedSuccessfully {
            isPresented = true
        }
    }

    func setTutorialProgress(_ progress: EnableAzooKeyViewProgress) {
        UserDefaults.standard.set(progress.rawValue, forKey: "tutorial_progress")
    }

    func markKeyboardActivated() {
        isKeyboardActivated = true
    }

    private var tutorialFinishedSuccessfully: Bool {
        guard let progressString = UserDefaults.standard.string(forKey: "tutorial_progress"),
              let progress = EnableAzooKeyViewProgress(rawValue: progressString) else {
            return true
        }
        return progress == .finish
    }
}
