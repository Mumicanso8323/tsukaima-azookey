import SwiftUI

@MainActor
struct AppRootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var keyboardConfiguration: KeyboardConfigurationState
    @EnvironmentObject private var onboarding: OnboardingState
    @EnvironmentObject private var customizationWalkthrough: CustomizationWalkthroughState
    @StateObject private var abGate = ABGateModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            AppTabView()
                .onAppear {
                    onboarding.presentInterruptedTutorialIfNeeded()
                }
                .task {
                    await AppLaunchTasks.performMaintenance()
                }
                .fullScreenCover(isPresented: $onboarding.isPresented, content: {
                    EnableAzooKeyView(resumeProgress: onboarding.resumeProgress)
                })
                .onChange(of: router.keyboardTab) { _, keyboardTab in
                    if keyboardTab == .customization {
                        customizationWalkthrough.presentIfNeeded()
                    }
                }
                .onOpenURL(perform: router.open)
                .sheet(isPresented: $customizationWalkthrough.isPresented, onDismiss: {
                    customizationWalkthrough.markDone()
                }, content: {
                    CustomizationWalkthroughView()
                        .background(Color.background)
                })
            AppDataUpdateOverlay()
            if router.importedFileURL != nil {
                URLImportCustardView(
                    manager: $keyboardConfiguration.custardManager,
                    url: $router.importedFileURL
                )
            }
        }
        // 開いたら rating とノアの絵柄の A/B を一つの cover で確認する(rating が常に先)。
        .fullScreenCover(isPresented: $abGate.isPresented) {
            switch abGate.mode {
            case .rate:
                ABRateGateView(model: abGate.rateGate)
            case .pair:
                ABGateView(model: abGate)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { abGate.checkOnForeground() }
        }
    }
}
