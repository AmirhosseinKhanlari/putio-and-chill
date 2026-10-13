import SwiftUI

struct AmbientBackground: View {
    let palette: AmbientPalette

    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [palette.primary.color.opacity(0.8), palette.primary.color.opacity(0.22), .clear],
                           center: UnitPoint(x: 0.8, y: 0.0), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [palette.secondary.color.opacity(0.35), .clear],
                           center: UnitPoint(x: 0.05, y: 1.0), startRadius: 0, endRadius: 700)
            LinearGradient(colors: [.clear, Theme.background.opacity(0.6)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: palette)
    }
}

private struct AmbientBackgroundModifier: ViewModifier {
    @Environment(AmbientController.self) private var ambient

    func body(content: Content) -> some View {
        content.background { AmbientBackground(palette: ambient.palette) }
    }
}

extension View {
    func ambientBackground() -> some View { modifier(AmbientBackgroundModifier()) }
}
