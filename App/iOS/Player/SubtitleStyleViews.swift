import AMDBKit
import SwiftUI

extension SubtitleStyle {
    func font(compact: Bool) -> Font {
        let base: CGFloat = compact ? 17 : 26
        let scale: CGFloat = switch size {
        case .small: 0.8
        case .medium: 1
        case .large: 1.25
        case .extraLarge: 1.5
        }
        let design: Font.Design = switch typeface {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        return .system(size: base * scale, weight: .semibold, design: design)
    }

    var textColor: Color {
        switch color {
        case .white: .white
        case .yellow: Color(red: 1, green: 0.88, blue: 0.2)
        case .cyan: Color(red: 0.4, green: 0.9, blue: 1)
        case .green: Color(red: 0.45, green: 0.95, blue: 0.5)
        }
    }

    var backgroundOpacity: Double {
        switch background {
        case .none: 0
        case .translucent: 0.45
        case .solid: 0.9
        }
    }
}

/// One subtitle line drawn in the user's style (used on the video and in the style preview).
struct StyledSubtitleText: View {
    let text: String
    let style: SubtitleStyle
    let compact: Bool

    var body: some View {
        Text(text)
            .font(style.font(compact: compact))
            .multilineTextAlignment(.center)
            .foregroundStyle(style.textColor)
            // Without a box, a heavier outline-like shadow keeps text readable on bright scenes.
            .shadow(color: .black.opacity(style.background == .none ? 1 : 0.8), radius: style.background == .none ? 1.5 : 2)
            .shadow(color: .black.opacity(style.background == .none ? 0.9 : 0), radius: 3)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.black.opacity(style.backgroundOpacity), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Size, background, color and typeface for subtitles, with a live preview over a sample frame.
struct SubtitleStyleEditor: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        Form {
            Section {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Color(red: 0.95, green: 0.75, blue: 0.45), Color(red: 0.35, green: 0.45, blue: 0.6),
                                            Color(red: 0.08, green: 0.1, blue: 0.16)],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                    StyledSubtitleText(text: "Do not go gentle\ninto that good night.", style: style, compact: false)
                        .padding(.bottom, 18)
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .listRowInsets(EdgeInsets())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Preview")
            }

            Section("Size") {
                Picker("Size", selection: $style.size) {
                    Text("S").tag(SubtitleStyle.Size.small)
                    Text("M").tag(SubtitleStyle.Size.medium)
                    Text("L").tag(SubtitleStyle.Size.large)
                    Text("XL").tag(SubtitleStyle.Size.extraLarge)
                }
                .pickerStyle(.segmented)
            }

            Section("Background") {
                Picker("Background", selection: $style.background) {
                    Text("None").tag(SubtitleStyle.Background.none)
                    Text("See-through").tag(SubtitleStyle.Background.translucent)
                    Text("Solid").tag(SubtitleStyle.Background.solid)
                }
                .pickerStyle(.segmented)
            }

            Section("Text color") {
                HStack(spacing: 14) {
                    ForEach(SubtitleStyle.TextColor.allCases, id: \.self) { color in
                        let sample = SubtitleStyle(color: color).textColor
                        Button { style.color = color } label: {
                            Circle().fill(sample)
                                .frame(width: 34, height: 34)
                                .overlay(Circle().strokeBorder(.white, lineWidth: style.color == color ? 3 : 0).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.rawValue.capitalized)
                        .accessibilityAddTraits(style.color == color ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Font") {
                Picker("Font", selection: $style.typeface) {
                    Text("Standard").tag(SubtitleStyle.Typeface.standard)
                    Text("Rounded").tag(SubtitleStyle.Typeface.rounded)
                    Text("Serif").tag(SubtitleStyle.Typeface.serif)
                    Text("Mono").tag(SubtitleStyle.Typeface.monospaced)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button("Reset to default") { style = .standard }
                    .disabled(style == .standard)
            }
        }
        .navigationTitle("Subtitle Style")
        .navigationBarTitleDisplayMode(.inline)
    }
}
