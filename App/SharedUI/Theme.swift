import SwiftUI

enum Theme {
    static let background = Color(red: 0.027, green: 0.027, blue: 0.043)
    static let sheet = Color(red: 0.075, green: 0.07, blue: 0.09)
    static let good = Color(red: 0.29, green: 0.87, blue: 0.5)
    static let okay = Color(red: 0.98, green: 0.8, blue: 0.08)
    static let poor = Color(red: 0.97, green: 0.44, blue: 0.44)

    static func seeders(_ count: Int?) -> Color {
        switch count ?? 0 {
        case 50...: good
        case 10..<50: okay
        default: poor
        }
    }
}

enum Metrics {
    static func poster(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat { sizeClass == .compact ? 112 : 150 }
    static func gutter(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat { sizeClass == .compact ? 16 : 32 }
    static func tabBarInset(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat { sizeClass == .compact ? 64 : 76 }
}

struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 20).padding(.vertical, 11)
            .foregroundStyle(.black)
            .background(.white, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct GlassPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .foregroundStyle(.white)
            .glassCapsule()
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct LiftStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryPillStyle { static var primaryPill: PrimaryPillStyle { PrimaryPillStyle() } }
extension ButtonStyle where Self == GlassPillStyle { static var glassPill: GlassPillStyle { GlassPillStyle() } }
extension ButtonStyle where Self == LiftStyle { static var lift: LiftStyle { LiftStyle() } }

extension View {
    @ViewBuilder func glassCapsule() -> some View {
        if #available(iOS 26.0, tvOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        }
    }

    @ViewBuilder func glassRounded(_ radius: CGFloat = 18) -> some View {
        if #available(iOS 26.0, tvOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.14)))
        }
    }
}
