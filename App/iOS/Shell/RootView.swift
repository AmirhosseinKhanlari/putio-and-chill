import AMDBKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @AppStorage("amdb.onboarded") private var onboarded = false

    var body: some View {
        Group {
            if app.isReady && !DemoMode.showsOnboarding && (onboarded || DemoMode.isEnabled) {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.isReady && onboarded)
        .makeRoomSheet(app, router: router)
    }
}
