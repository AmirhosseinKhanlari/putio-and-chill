import AMDBKit
import AVKit
import SwiftUI

/// Everything around the picture that isn't playback state: title, overlays, subtitles, and what the buttons do.
@Observable @MainActor
final class PlayerChrome {
    let title: String
    let subtitle: String?
    let subtitles: SubtitleFinder?
    var controlsVisible = true
    var preparing = false
    /// put.io is converting the video for Apple devices; playback starts when it's done.
    var conversion: VideoConversions.State?
    var failure: String?
    var failureLink: URL?
    /// "S1 E2" for the bottom bar's Next button.
    var nextLabel: String?
    /// The episode after this one (Netflix-style Next Episode card), when there is one.
    var nextUp: NextUp?
    var nextUpCard: NextUpCardState = .hidden
    /// Counts down and plays the next episode by itself (Settings → Auto-play next episode; not with a sleep timer).
    var nextUpAutoplay = true
    var nextUpGetting: NextUpGetting?
    var pipSupported = false
    var pipActive = false
    var fillsScreen = false
    /// Playing the downloaded copy rather than streaming.
    var playingFromDevice = false
    var subtitleStyle = SubtitleStyle.standard
    /// Stops playback after a while or at the end of the episode.
    var sleepTimer: SleepTimer?
    /// "29:41 left", refreshed by the coordinator every second.
    var sleepLabel: String?

    /// "Movie details" / "Show details" in the top bar: closes the player and opens the title's page.
    var detailsLabel: String?
    @ObservationIgnored var onDetails: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onNext: () -> Void = {}
    @ObservationIgnored var onWatchCredits: () -> Void = {}
    @ObservationIgnored var onChooseNextVersion: () -> Void = {}
    @ObservationIgnored var onTogglePiP: () -> Void = {}
    @ObservationIgnored var onFillChanged: (Bool) -> Void = { _ in }
    @ObservationIgnored var onStyleChanged: (SubtitleStyle) -> Void = { _ in }
    /// Swipe down on the video to close: how far, and (at the end) how far it would have gone.
    @ObservationIgnored var onSwipeDownChanged: (CGFloat) -> Void = { _ in }
    @ObservationIgnored var onSwipeDownEnded: (_ drag: CGFloat, _ predicted: CGFloat) -> Void = { _, _ in }

    init(title: String, subtitle: String? = nil, subtitles: SubtitleFinder? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.subtitles = subtitles
    }
}

/// The app's player controls, drawn over the video: top bar, center transport, scrubber, and option buttons.
/// Tap toggles them (they hide while playing), double-tap a side skips 10 s, pinch fills or fits the screen.
struct PlayerControlsView: View {
    let engine: PlayerEngine
    let chrome: PlayerChrome
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var scrubbing: Double?
    @State private var showOptions = false
    @State private var hideToken = 0
    @State private var skipFlash: (forward: Bool, id: Int)?

    private var regular: Bool { sizeClass != .compact }
    private var visible: Bool { chrome.controlsVisible || !engine.isPlaying || scrubbing != nil }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                gestureSurface(width: proxy.size.width)
                if let subtitles = chrome.subtitles {
                    SubtitleOverlayView(finder: subtitles, engine: engine, videoRect: videoRect(in: proxy.size),
                                        style: chrome.subtitleStyle, liftedBy: visible ? (regular ? 150 : 110) : 0)
                }
                if visible {
                    controls
                        .transition(.opacity)
                } else if engine.isBuffering {
                    ProgressView().controlSize(.large).tint(.white)
                }
                skipIndicator(width: proxy.size.width)
                if let conversion = chrome.conversion, conversion != .failed, chrome.failure == nil {
                    ConversionCard(state: conversion)
                } else if chrome.preparing, chrome.failure == nil {
                    Text("Preparing…").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 7).glassCapsule()
                        .offset(y: 90)
                }
                if chrome.nextUpCard != .hidden, let next = chrome.nextUp {
                    NextUpCard(next: next, chrome: chrome, regular: regular, liftedBy: visible ? (regular ? 150 : 110) : 0)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if let failure = chrome.failure {
                    PlayerFailureView(message: failure, link: chrome.failureLink, close: chrome.onClose)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: visible)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: chrome.nextUpCard)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(!visible)
        .persistentSystemOverlays(visible ? .automatic : .hidden)
        .sheet(isPresented: $showOptions) {
            if let finder = chrome.subtitles {
                SubtitleSheet(finder: finder, engine: engine, style: Binding(get: { chrome.subtitleStyle }, set: { style in
                    chrome.subtitleStyle = style
                    chrome.onStyleChanged(style)
                })) {}
                    .presentationDetents([.medium, .large])
            }
        }
        .task(id: hideToken) { await autoHide() }
        .onChange(of: engine.isPlaying) { _, playing in if playing { poke() } }
        .onChange(of: showOptions) { _, open in if !open { poke() } }
    }

    // MARK: Layout

    private var controls: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: .clear, location: 0.6), .init(color: .black.opacity(0.8), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, regular ? 32 : 20)
            .padding(.vertical, regular ? 24 : 14)
            .safeAreaPadding(.all)
            centerTransport
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            circleButton("xmark", label: "Close", size: 44, key: .escape) { chrome.onClose() }
            VStack(alignment: .leading, spacing: 2) {
                Text(chrome.title).font(.headline).lineLimit(1)
                if let subtitle = chrome.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let detailsLabel = chrome.detailsLabel {
                circleButton("info", label: detailsLabel, size: 44) { chrome.onDetails() }
            }
            if chrome.playingFromDevice {
                Label("On this device", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).frame(height: 32)
                    .glassCapsule()
            }
            RoutePicker()
                .frame(width: 44, height: 44)
                .glassCapsule()
                .accessibilityLabel("AirPlay")
            if chrome.pipSupported {
                circleButton(chrome.pipActive ? "pip.exit" : "pip.enter", label: "Picture in Picture", size: 44) {
                    chrome.onTogglePiP()
                }
            }
        }
    }

    private var centerTransport: some View {
        HStack(spacing: regular ? 72 : 48) {
            circleButton("gobackward.10", label: "Skip back 10 seconds", size: regular ? 64 : 52, key: .leftArrow) { skip(-10) }
            Button { engine.togglePlay(); poke() } label: {
                ZStack {
                    if engine.isBuffering, engine.isPlaying {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: regular ? 38 : 30, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: regular ? 92 : 76, height: regular ? 92 : 76)
                .glassCapsule()
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
            // Space plays and pauses (Mac, or an iPad with a keyboard).
            .keyboardShortcut(.space, modifiers: [])
            circleButton("goforward.10", label: "Skip forward 10 seconds", size: regular ? 64 : 52, key: .rightArrow) { skip(10) }
        }
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        VStack(spacing: regular ? 14 : 10) {
            Scrubber(position: scrubbing ?? engine.position, duration: engine.duration, buffered: engine.buffered,
                     onScrub: { value in scrubbing = value },
                     onCommit: { value in
                         engine.seek(to: value)
                         scrubbing = nil
                         poke()
                     })
            HStack(spacing: regular ? 12 : 8) {
                Text(timeLabel).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 8)
                sleepMenu
                speedMenu
                if chrome.subtitles != nil {
                    pillButton(chrome.subtitles?.isShowing == true ? "captions.bubble.fill" : "captions.bubble",
                               title: regular ? "Subtitles" : nil, label: "Subtitles") { showOptions = true }
                }
                if let label = chrome.nextLabel {
                    pillButton("forward.end.fill", title: regular ? "Next" : nil, label: "Next episode \(label)") { chrome.onNext() }
                }
                pillButton(chrome.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           title: nil, label: chrome.fillsScreen ? "Fit to screen" : "Fill screen") { toggleFill() }
            }
        }
    }

    private var sleepMenu: some View {
        Menu {
            if chrome.sleepTimer != nil {
                Button(role: .destructive) { chrome.sleepTimer = nil; chrome.sleepLabel = nil; poke() } label: {
                    Label("Turn Off", systemImage: "moon.zzz")
                }
            }
            ForEach(SleepTimer.Option.choices, id: \.self) { option in
                Button { chrome.sleepTimer = SleepTimer(option, startedAt: .now); poke() } label: {
                    if chrome.sleepTimer?.option == option { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: chrome.sleepTimer == nil ? "moon" : "moon.fill")
                if let label = chrome.sleepLabel, regular || chrome.sleepTimer != nil {
                    Text(label.replacingOccurrences(of: " left", with: "")).monospacedDigit()
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).frame(height: 44)
            .background(.white.opacity(chrome.sleepTimer == nil ? 0.12 : 0.25), in: Capsule())
            .contentShape(Capsule())
        }
        .foregroundStyle(.white)
        .accessibilityLabel(chrome.sleepLabel.map { "Sleep timer, \($0)" } ?? "Sleep timer")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                Button { engine.rate = rate; poke() } label: {
                    if engine.rate == rate { Label(Self.speedText(rate), systemImage: "checkmark") } else { Text(Self.speedText(rate)) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                if regular || engine.rate != 1 { Text(Self.speedText(engine.rate)).monospacedDigit() }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
            .glassCapsule()
            .contentShape(Capsule())
        }
        .tint(.white)
        .accessibilityLabel("Playback speed")
    }

    // MARK: Gestures

    private func gestureSurface(width: CGFloat) -> some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    skip(value.location.x < width / 2 ? -10 : 10)
                }
                .exclusively(before: TapGesture().onEnded { toggleControls() })
            )
            // Swipe down to close. Only on the video itself, so buttons above it keep their own touches.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24, coordinateSpace: .global)
                    .onChanged { value in
                        guard value.translation.height > 0,
                              abs(value.translation.height) > abs(value.translation.width) * 1.5 else { return }
                        chrome.onSwipeDownChanged(value.translation.height - 24)
                    }
                    .onEnded { value in
                        let vertical = abs(value.translation.height) > abs(value.translation.width) * 1.5
                        chrome.onSwipeDownEnded(vertical ? value.translation.height - 24 : 0,
                                                vertical ? value.predictedEndTranslation.height - 24 : 0)
                    }
            )
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                if value.magnification > 1.1, !chrome.fillsScreen { toggleFill() }
                if value.magnification < 0.9, chrome.fillsScreen { toggleFill() }
            })
            .accessibilityHidden(true)
    }

    @ViewBuilder private func skipIndicator(width: CGFloat) -> some View {
        if let flash = skipFlash {
            HStack {
                if flash.forward { Spacer() }
                Label(flash.forward ? "10" : "10", systemImage: flash.forward ? "goforward.10" : "gobackward.10")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 96, height: 96)
                    .glassCapsule()
                    .padding(.horizontal, width * 0.12)
                if !flash.forward { Spacer() }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .id(flash.id)
            .allowsHitTesting(false)
        }
    }

    // MARK: Actions

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { chrome.controlsVisible.toggle() }
        if chrome.controlsVisible { poke() }
    }

    private func skip(_ seconds: Double) {
        engine.skip(by: seconds)
        let id = (skipFlash?.id ?? 0) + 1
        withAnimation(.snappy) { skipFlash = (seconds > 0, id) }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if skipFlash?.id == id { withAnimation(.easeOut) { skipFlash = nil } }
        }
        poke()
    }

    private func toggleFill() {
        chrome.fillsScreen.toggle()
        chrome.onFillChanged(chrome.fillsScreen)
        poke()
    }

    /// Any interaction restarts the auto-hide timer.
    private func poke() {
        if !chrome.controlsVisible { withAnimation(.easeInOut(duration: 0.2)) { chrome.controlsVisible = true } }
        hideToken += 1
    }

    private func autoHide() async {
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled, engine.isPlaying, scrubbing == nil, !showOptions else { return }
        withAnimation(.easeInOut(duration: 0.3)) { chrome.controlsVisible = false }
    }

    // MARK: Pieces

    /// `key`: the keyboard key for it (Mac, or an iPad with a keyboard): Esc closes, ← → skip.
    private func circleButton(_ symbol: String, label: String, size: CGFloat, key: KeyEquivalent? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassCapsule()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .modifier(OptionalShortcut(key: key))
    }

    private func pillButton(_ symbol: String, title: String?, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if let title { Text(title) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
            .glassCapsule()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var timeLabel: String {
        let position = Int(scrubbing ?? engine.position)
        guard engine.duration > 0 else { return Format.clock(position) }
        return "\(Format.clock(position)) / −\(Format.clock(max(Int(engine.duration) - position, 0)))"
    }

    private static func speedText(_ rate: Float) -> String {
        rate == 1 ? "1×" : String(format: "%g×", rate)
    }

    /// Where the picture sits: aspect-fit inside the screen, or the whole screen when filling.
    private func videoRect(in size: CGSize) -> CGRect {
        let video = engine.presentationSize
        guard !chrome.fillsScreen, video.width > 0, video.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / video.width, size.height / video.height)
        let fitted = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}

/// Timeline with buffered range, a draggable thumb and a time bubble while scrubbing.
struct Scrubber: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
            let loaded = duration > 0 ? min(max(buffered / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.35)).frame(width: width * loaded)
                Capsule().fill(.white).frame(width: width * progress)
                Circle().fill(.white)
                    .frame(width: dragging ? 22 : 14, height: dragging ? 22 : 14)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .offset(x: width * progress - (dragging ? 11 : 7))
                if dragging {
                    Text(Format.clock(Int(position)))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassCapsule()
                        .fixedSize()
                        .offset(x: min(max(width * progress - 28, 0), width - 64), y: -30)
                }
            }
            .frame(height: dragging ? 8 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0 else { return }
                dragging = true
                onScrub(min(max(value.location.x / width, 0), 1) * duration)
            }.onEnded { value in
                guard duration > 0 else { return }
                dragging = false
                onCommit(min(max(value.location.x / width, 0), 1) * duration)
            })
            .animation(.snappy(duration: 0.15), value: dragging)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Format.clock(Int(position))) of \(Format.clock(Int(duration)))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(min(position + 10, duration))
            case .decrement: onCommit(max(position - 10, 0))
            @unknown default: break
            }
        }
    }
}

/// AirPlay button.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct PlayerFailureView: View {
    let message: String
    let link: URL?
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(message).multilineTextAlignment(.center)
                if let link {
                    Link("Open in put.io", destination: link).buttonStyle(.glassPill)
                }
                Button("Close", action: close).buttonStyle(.primaryPill)
            }
            .padding(28)
            .glassRounded(24)
            .padding(40)
        }
    }
}


enum NextUpCardState: Equatable {
    case hidden
    /// The credits have started.
    case credits
    /// The episode has ended.
    case end
}

enum NextUpGetting: Equatable {
    case searching
    case downloading(percent: Int)
    case failed(String)
}

/// Netflix-style Next Episode: a picture and title of the next episode, Watch Credits, and a Next Episode button that
/// fills up as it counts down, then plays. Not in put.io yet: Get Next Episode sends it there and plays when ready.
struct NextUpCard: View {
    let next: NextUp
    let chrome: PlayerChrome
    let regular: Bool
    let liftedBy: CGFloat
    @State private var fill: Double = 0

    private var counting: Bool { chrome.nextUpAutoplay && next.isInPutio && chrome.nextUpGetting == nil }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                card.frame(width: regular ? 400 : 360)
            }
        }
        .padding(.horizontal, regular ? 32 : 20)
        .padding(.bottom, liftedBy + (regular ? 28 : 16))
        .safeAreaPadding(.all)
        .task(id: chrome.nextUpCard) { await countdown() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(path: next.stillPath, size: "w300", seed: next.name)
                    .frame(width: regular ? 136 : 104, height: regular ? 76 : 58)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("NEXT EPISODE").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(.white.opacity(0.6))
                    Text("\(next.label) · \(next.name)").font(.subheadline.weight(.semibold)).lineLimit(2)
                    if regular, !next.overview.isEmpty {
                        Text(next.overview).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    }
                }
            }
            status
            HStack(spacing: 10) {
                Button { chrome.onWatchCredits() } label: { Text("Watch Credits").lineLimit(1).fixedSize() }
                    .buttonStyle(.glassPill)
                    .opacity(chrome.nextUpCard == .credits ? 1 : 0)
                    .disabled(chrome.nextUpCard != .credits)
                primary
            }
        }
        .padding(14)
        .glassRounded(22)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var status: some View {
        switch chrome.nextUpGetting {
        case .searching?:
            Label("Finding the best version…", systemImage: "magnifyingglass").font(.caption).foregroundStyle(.white.opacity(0.75))
        case let .downloading(percent)?:
            VStack(alignment: .leading, spacing: 4) {
                Text("Getting it from put.io… \(percent)%").font(.caption).foregroundStyle(.white.opacity(0.75))
                ProgressView(value: Double(percent), total: 100).tint(.white)
            }
        case let .failed(message)?:
            Text(message).font(.caption).foregroundStyle(.white.opacity(0.75))
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var primary: some View {
        if case .failed? = chrome.nextUpGetting {
            Button { chrome.onChooseNextVersion() } label: { Label("Choose Version", systemImage: "square.stack.3d.up") }
                .buttonStyle(.primaryPill)
        } else if next.isInPutio {
            Button { chrome.onNext() } label: {
                Label("Next Episode", systemImage: "play.fill")
                    .lineLimit(1)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18).frame(height: 44)
                    .frame(maxWidth: .infinity)
                    .background {
                        // Fills left to right as it counts down, like Netflix.
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.75))
                                Capsule().fill(.white).frame(width: proxy.size.width * (counting ? fill : 1))
                            }
                        }
                    }
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next episode, \(next.label)")
        } else {
            Button { chrome.onNext() } label: {
                Label(chrome.nextUpGetting == nil ? "Get Next Episode" : "Getting…", systemImage: "icloud.and.arrow.down")
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryPill)
            .disabled(chrome.nextUpGetting != nil)
        }
    }

    private func countdown() async {
        fill = 0
        guard counting, chrome.nextUpCard != .hidden else { return }
        withAnimation(.linear(duration: NextUp.countdown)) { fill = 1 }
        try? await Task.sleep(for: .seconds(NextUp.countdown))
        guard !Task.isCancelled, counting, chrome.nextUpCard != .hidden else { return }
        chrome.onNext()
    }
}

/// "Converting for Apple devices": put.io turns a video Apple devices can't play into an MP4 first.
private struct ConversionCard: View {
    let state: VideoConversions.State

    var body: some View {
        VStack(spacing: 12) {
            switch state {
            case let .converting(percent):
                ProgressRing(progress: Double(percent) / 100, lineWidth: 5)
                    .frame(width: 54, height: 54)
                    .overlay { Text("\(percent)%").font(.caption.monospacedDigit().weight(.semibold)) }
                    .animation(.easeInOut, value: percent)
                Text("Converting for Apple devices").font(.headline)
            default:
                ProgressView().controlSize(.large).tint(.white).frame(width: 54, height: 54)
                Text("Waiting for put.io to convert it").font(.headline)
            }
            Text("This video's format doesn't play on iPhone and iPad as it is, so put.io is converting it. It plays by itself when it's ready. You can close the player: it keeps converting, and shows how far when you come back.")
                .font(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
        }
        .padding(22)
        .frame(maxWidth: 380)
        .glassRounded(22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        if case let .converting(percent) = state { return "Converting for Apple devices, \(percent) percent" }
        return "Waiting for put.io to convert it"
    }
}

/// A key (without ⌘) for a button, when there is one.
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key, modifiers: []) } else { content }
    }
}
