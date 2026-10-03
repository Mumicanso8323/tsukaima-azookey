import SwiftUI

@main
struct MainApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var router = AppRouter()
    @StateObject private var keyboardConfiguration = KeyboardConfigurationState()
    @StateObject private var onboarding = OnboardingState()
    @StateObject private var reviewPrompt = RequestReviewManager()
    @StateObject private var customizationWalkthrough = CustomizationWalkthroughState()

    var body: some Scene {
        WindowGroup {
            if TsukaimaInputLab.isActive {
                // UI テスト専用: 入力欄の試験台(本番の起動では出ない)
                TsukaimaInputLab()
            } else {
                AppRootView()
                    .environmentObject(router)
                    .environmentObject(keyboardConfiguration)
                    .environmentObject(onboarding)
                    .environmentObject(reviewPrompt)
                    .environmentObject(customizationWalkthrough)
                    .onAppear {
                        AppLaunchTasks.performInitialSetup()
                    }
            }
        }
    }
}
