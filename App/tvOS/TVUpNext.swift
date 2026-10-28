import AMDBCore
import AMDBKit
import SwiftUI

/// The end-of-episode screen, like Apple's TV app: the video (the credits) keeps playing small at the top left
/// (`TVPlayerHostController`), and below it the next episode, with Play Next filling up as its countdown runs and
/// Watch Credits to go back to the full picture. Same for Apple's player and the built-in one.
struct TVUpNextState {
    let next: NextUp
    /// Play Next (or Get Next Episode, its progress, Choose Version).
    var primary: TVMenuItem
    /// Watch Credits; none at the very end, or while the next episode is being fetched.
    var secondary: TVMenuItem?
    /// When the countdown started, if it runs: Play Next fills up over `NextUp.countdown` seconds.
    var countdownStarted: Date?
    /// Fetching the next episode: how far along (0…1).
    var progress: Double?
}

@Observable @MainActor
final class TVUpNextModel {
    var state: TVUpNextState?
}

enum TVUpNextLayout {
    static let inset = CGSize(width: 90, height: 60)

    /// Where the video goes while the panel shows: the top left, 16:9, a bit under half the width.
    static func videoRect(in bounds: CGRect) -> CGRect {
        let width = (bounds.width * 0.46).rounded()
        return CGRect(x: inset.width, y: inset.height, width: width, height: (width * 9 / 16).rounded())
    }
}

struct TVUpNextPanel: View {
    let model: TVUpNextModel

    var body: some View {
        GeometryReader { proxy in
            if let state = model.state {
                let video = TVUpNextLayout.videoRect(in: CGRect(origin: .zero, size: proxy.size))
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: video.maxY + 48)
                    HStack(alignment: .top, spacing: 48) {
                        RemoteImage(path: state.next.stillPath, size: "w780", seed: state.next.name)
                            .frame(width: 480, height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
                        VStack(alignment: .leading, spacing: 12) {
                            Text("NEXT EPISODE").font(.system(size: 22, weight: .semibold)).tracking(3)
                                .foregroundStyle(TVMetrics.secondaryText)
                            Text(state.next.name.isEmpty ? state.next.label : "\(state.next.label) · \(state.next.name)")
                                .font(.system(size: 40, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                            if !state.next.overview.isEmpty {
                                Text(state.next.overview).font(.system(size: 24)).foregroundStyle(TVMetrics.secondaryText)
                                    .lineLimit(2).frame(maxWidth: 980, alignment: .leading)
                            }
                            HStack(spacing: 28) {
                                PrimaryButton(item: state.primary, countdownStarted: state.countdownStarted, progress: state.progress)
                                if let secondary = state.secondary {
                                    Button { secondary.action?() } label: {
                                        Label(secondary.title, systemImage: secondary.symbol ?? "text.append")
                                    }
                                    .buttonStyle(UpNextButtonStyle(prominent: false, fill: nil))
                                }
                            }
                            .padding(.top, 18)
                            .focusSection()
                        }
                    }
                    .padding(.horizontal, TVUpNextLayout.inset.width)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(LinearGradient(colors: [Color(white: 0.09), .black], startPoint: .top, endPoint: .bottom))
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: model.state == nil)
    }
}

/// Play Next, filling up while its countdown runs (or with the download's progress).
private struct PrimaryButton: View {
    let item: TVMenuItem
    let countdownStarted: Date?
    let progress: Double?

    var body: some View {
        TimelineView(.animation(paused: countdownStarted == nil)) { timeline in
            let fill = countdownStarted.map { min(1, timeline.date.timeIntervalSince($0) / NextUp.countdown) } ?? progress
            Button { item.action?() } label: {
                Label(item.title, systemImage: item.symbol ?? "play.fill")
            }
            .buttonStyle(UpNextButtonStyle(prominent: true, fill: fill))
            .disabled(item.action == nil)
        }
    }
}

private struct UpNextButtonStyle: ButtonStyle {
    let prominent: Bool
    let fill: Double?

    func makeBody(configuration: Configuration) -> some View {
        UpNextButtonBody(configuration: configuration, prominent: prominent, fill: fill)
    }

    private struct UpNextButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        let fill: Double?
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(focused ? Color.black : .white)
                .padding(.horizontal, 44).frame(height: 80)
                .background {
                    ZStack(alignment: .leading) {
                        Capsule().fill(focused ? .white : .white.opacity(prominent ? 0.2 : 0.1))
                        if let fill {
                            GeometryReader { proxy in
                                Rectangle().fill(focused ? Color.black.opacity(0.14) : .white.opacity(0.22))
                                    .frame(width: proxy.size.width * max(0, min(1, fill)))
                            }
                        }
                    }
                    .clipShape(Capsule())
                }
                .scaleEffect(focused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
