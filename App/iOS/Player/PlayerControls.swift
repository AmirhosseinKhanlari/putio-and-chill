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
    var failure: String?
    var failureLink: URL?
    /// "S1 · E2" while the next-episode button is offered near the end.
    var nextLabel: String?
    var showNextButton = false
    var showCountdown = false
    var pipSupported = false
    var pipActive = false
    var fillsScreen = false
    var subtitleStyle = SubtitleStyle.standard

    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onNext: () -> Void = {}
    @ObservationIgnored var onCancelCountdown: () -> Void = {}
    @ObservationIgnored var onTogglePiP: () -> Void = {}
    @ObservationIgnored var onFillChanged: (Bool) -> Void = { _ in }
    @ObservationIgnored var onStyleChanged: (SubtitleStyle) -> Void = { _ in }

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
                if chrome.preparing, chrome.failure == nil {
                    Text("Preparing…").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 7).glassCapsule()
                        .offset(y: 90)
                }
                if chrome.showNextButton, !chrome.showCountdown, let label = chrome.nextLabel {
                    nextButton(label)
                }
                if chrome.showCountdown, let label = chrome.nextLabel {
                    NextEpisodeCountdown(label: label, onPlay: chrome.onNext, onCancel: chrome.onCancelCountdown)
                }
                if let failure = chrome.failure {
                    PlayerFailureView(message: failure, link: chrome.failureLink, close: chrome.onClose)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: visible)
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
            circleButton("xmark", label: "Close", size: 44) { chrome.onClose() }
            VStack(alignment: .leading, spacing: 2) {
                Text(chrome.title).font(.headline).lineLimit(1)
                if let subtitle = chrome.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
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
            circleButton("gobackward.10", label: "Skip back 10 seconds", size: regular ? 64 : 52) { skip(-10) }
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
            circleButton("goforward.10", label: "Skip forward 10 seconds", size: regular ? 64 : 52) { skip(10) }
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
            .padding(.horizontal, 12).frame(minWidth: 40, minHeight: 40)
            .glassCapsule()
        }
        .tint(.white)
        .accessibilityLabel("Playback speed")
    }

    private func nextButton(_ label: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { chrome.onNext() } label: { Label("Next: \(label)", systemImage: "forward.end.fill") }
                    .buttonStyle(.primaryPill)
            }
        }
        .padding(.horizontal, regular ? 32 : 20)
        .padding(.bottom, visible ? (regular ? 150 : 110) : 40)
        .safeAreaPadding(.all)
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

    private func circleButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func pillButton(_ symbol: String, title: String?, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if let title { Text(title) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(minWidth: 40, minHeight: 40)
            .glassCapsule()
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

struct NextEpisodeCountdown: View {
    let label: String
    let onPlay: () -> Void
    let onCancel: () -> Void
    @State private var remaining = 5
    @State private var started = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    ProgressRing(progress: Double(5 - remaining) / 5, lineWidth: 5)
                    Text("\(remaining)").font(.system(size: 34, weight: .ultraLight)).monospacedDigit()
                }
                .frame(width: 88, height: 88)
                Text("Next episode").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                Text(label).font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    Button { go() } label: { Label("Play Now", systemImage: "play.fill") }.buttonStyle(.primaryPill)
                    Button("Cancel", action: onCancel).buttonStyle(.glassPill)
                }
            }
            .padding(32)
            .glassRounded(28)
        }
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                remaining -= 1
            }
            go()
        }
    }

    private func go() {
        guard !started else { return }
        started = true
        onPlay()
    }
}
