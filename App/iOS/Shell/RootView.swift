import AMDBKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("amdb.onboarded") private var onboarded = false

    var body: some View {
        Group {
            if app.isReady && (onboarded || DemoMode.isEnabled) {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.isReady && onboarded)
    }
}
