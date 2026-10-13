import AMDBKit
import SwiftUI

struct MainView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 16) {
            Text("AMDB").font(.system(size: 48, weight: .ultraLight)).tracking(8)
            Button("Settings") { router.showSettings = true }.buttonStyle(.glassPill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ambientBackground()
        .sheet(isPresented: $router.showSettings) { SettingsView() }
    }
}
