import AMDBKit
import SwiftUI
import UIKit

/// What the built-in player's TV screen shows around the picture: title, the menus (Subtitles, Audio, Speed, Sleep
/// Timer…), the Next Episode buttons and a failure message. Filled by TVPlaybackCoordinator.
@Observable @MainActor
final class TVBuiltInChrome {
    var title = ""
    var subtitle: String?
    var menus: [TVMenu] = []
    /// Next Episode / Watch Credits, shown bottom right (like Apple's player's contextual buttons).
    var nextActions: [TVMenuItem] = [] { didSet { if nextActions.map(\.title) != oldValue.map(\.title) { onFocusChange() } } }
    var message: String?
    var panelOpen = false { didSet { if panelOpen != oldValue { onFocusChange() } } }
    var selectedMenu: String?
    var barVisible = true
    /// Swiping on the remote: where playback will jump when the click comes (nil when not scrubbing).
    var scrubTarget: Double?
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onFocusChange: () -> Void = {}
}

/// Holds whichever player is on screen: Apple's (AVPlayerViewController) or the built-in one, switching when the
/// routing moves a video from one to the other.
final class TVPlayerHostController: UIViewController {
    private(set) var current: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    func show(_ child: UIViewController) {
        guard child !== current else { return }
        if let current {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
        current = child
        setNeedsFocusUpdate()
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { current.map { [$0] } ?? [] }
}

/// A full-screen view that takes focus while nothing else on the built-in player's screen can, so the remote's
/// clicks and swipes come to the player.
private final class RemoteSurface: UIView {
    override var canBecomeFocused: Bool { true }
}

/// The built-in player on Apple TV, with Siri Remote conventions: click or Play/Pause plays and pauses, left/right
/// skip 10 seconds, swipe sideways to scrub (click to jump there), swipe down for Subtitles, Audio and Speed, and
/// Menu/Back closes (or backs out of a menu or a scrub first).
final class TVBuiltInPlayerController: UIViewController {
    private let engine: PlayerEngine
    private let chrome: TVBuiltInChrome
    private let line: TVSubtitleLine
    private let surface = RemoteSurface()
    private var hosting: UIHostingController<TVBuiltInOverlay>?
    private var hideTask: Task<Void, Never>?
    private var panStart: Double = 0
    /// A Menu press that began here (one that began in the panel is the panel's).
    private var menuPressBegan = false

    init(engine: PlayerEngine, chrome: TVBuiltInChrome, line: TVSubtitleLine) {
        self.engine = engine
        self.chrome = chrome
        self.line = line
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let picture = engine.backend.videoView
        picture.frame = view.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(picture)

        surface.frame = view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(surface)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        surface.addGestureRecognizer(pan)

        let overlay = UIHostingController(rootView: TVBuiltInOverlay(engine: engine, chrome: chrome, line: line))
        overlay.view.backgroundColor = .clear
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(overlay)
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
        hosting = overlay

        chrome.onFocusChange = { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
        showBar()
    }

    /// The menus panel and the Next Episode buttons take focus when they show; otherwise the remote drives playback.
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if chrome.panelOpen || !chrome.nextActions.isEmpty || chrome.message != nil, let hosting { return [hosting.view] }
        return [surface]
    }

    // MARK: Remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else { return super.pressesBegan(presses, with: event) }
        let onSurface = surface.isFocused
        switch press.type {
        case .menu:
            // Handled when the press ends: tvOS's own Menu handling (closing the screen) runs there too.
            menuPressBegan = true
        case .playPause:
            commitScrubOrToggle()
        case .select where onSurface:
            commitScrubOrToggle()
        case .leftArrow where onSurface:
            step(-10)
        case .rightArrow where onSurface:
            step(10)
        case .downArrow where onSurface:
            openPanel()
        case .upArrow where onSurface:
            showBar()
        default:
            if press.key?.keyCode == .keyboardSpacebar { commitScrubOrToggle() } else { super.pressesBegan(presses, with: event) }
        }
    }

    /// Menu backs out one step: the menus panel, then a scrub, then the player.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else { return super.pressesEnded(presses, with: event) }
        guard menuPressBegan else { return }
        menuPressBegan = false
        backOut()
    }

    fileprivate func backOut() {
        if chrome.panelOpen { chrome.panelOpen = false; showBar() }
        else if chrome.scrubTarget != nil { chrome.scrubTarget = nil; showBar() }
        else { chrome.onClose() }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !presses.contains(where: { $0.type == .menu }) else { return }
        super.pressesChanged(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !presses.contains(where: { $0.type == .menu }) else { return }
        super.pressesCancelled(presses, with: event)
    }

    private func commitScrubOrToggle() {
        if let target = chrome.scrubTarget {
            chrome.scrubTarget = nil
            engine.seek(to: target)
            engine.play()
        } else {
            engine.togglePlay()
        }
        showBar()
    }

    /// ±10 s; while scrubbing it moves the scrub point instead.
    private func step(_ seconds: Double) {
        if let target = chrome.scrubTarget {
            chrome.scrubTarget = clamp(target + seconds)
        } else {
            engine.skip(by: seconds)
        }
        showBar()
    }

    private func openPanel() {
        guard !chrome.menus.isEmpty else { return }
        if chrome.selectedMenu == nil { chrome.selectedMenu = chrome.menus.first?.title }
        chrome.panelOpen = true
    }

    /// Sideways: scrub (playback pauses; click jumps there). Down: the menus.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard surface.isFocused, engine.duration > 0 else { return }
        let move = pan.translation(in: surface)
        switch pan.state {
        case .began:
            panStart = chrome.scrubTarget ?? engine.position
        case .changed:
            if abs(move.x) > abs(move.y) * 1.5, abs(move.x) > 30 {
                if chrome.scrubTarget == nil { engine.pause() }
                // A full swipe across the remote covers about a fifth of the video (at least 5 minutes).
                let span = max(300, engine.duration / 5)
                chrome.scrubTarget = clamp(panStart + Double(move.x) / 900 * span)
                showBar()
            }
        case .ended:
            if move.y > 220, move.y > abs(move.x) * 2, chrome.scrubTarget == nil { openPanel() }
        default:
            break
        }
    }

    private func clamp(_ seconds: Double) -> Double { min(max(0, seconds), max(0, engine.duration - 1)) }

    /// Shows the transport bar; it hides again after a few seconds of playing.
    private func showBar() {
        chrome.barVisible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, engine.isPlaying, chrome.scrubTarget == nil, !chrome.panelOpen else { return }
            withAnimation(.easeOut(duration: 0.3)) { chrome.barVisible = false }
        }
    }
}

/// Everything drawn over the built-in player's picture on the TV.
struct TVBuiltInOverlay: View {
    let engine: PlayerEngine
    let chrome: TVBuiltInChrome
    let line: TVSubtitleLine

    private var barShowing: Bool { chrome.barVisible || !engine.isPlaying || chrome.scrubTarget != nil }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                embeddedImages(in: videoRect(proxy.size))
                TVSubtitleOverlay(line: line)
                    .padding(.bottom, barShowing ? 150 : 0)
                    .animation(.easeInOut(duration: 0.25), value: barShowing)
                if engine.status == .loading || (engine.isBuffering && engine.isPlaying) {
                    ProgressView().scaleEffect(2)
                }
                if barShowing { transportBar.transition(.opacity) }
                if !chrome.nextActions.isEmpty { nextButtons }
                if chrome.panelOpen { panel.transition(.move(edge: .top).combined(with: .opacity)) }
                if let message = chrome.message { failure(message) }
            }
            .animation(.easeInOut(duration: 0.25), value: barShowing)
            .animation(.easeInOut(duration: 0.25), value: chrome.panelOpen)
        }
        .ignoresSafeArea()
        // Menu while the panel or a button here has focus: close the panel first, else the player.
        .onExitCommand {
            if chrome.panelOpen { chrome.panelOpen = false } else { chrome.onClose() }
        }
    }

    // MARK: Transport

    private var transportBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text(chrome.title).font(.system(size: 38, weight: .semibold)).lineLimit(1)
                if let subtitle = chrome.subtitle {
                    Text(subtitle).font(.system(size: 26)).foregroundStyle(TVMetrics.secondaryText)
                }
            }
            scrubber
            HStack {
                Text(Format.clock(Int(shownPosition))).monospacedDigit()
                Spacer()
                if engine.airPlayNotice == nil {
                    Text(chrome.scrubTarget != nil ? "Click to jump here · Menu to cancel" : "Swipe down for Subtitles, Audio and Speed")
                        .foregroundStyle(TVMetrics.secondaryText)
                }
                Spacer()
                Text("−" + Format.clock(max(0, Int(engine.duration - shownPosition)))).monospacedDigit()
            }
            .font(.system(size: 24, weight: .medium))
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 420)
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    private var shownPosition: Double { chrome.scrubTarget ?? engine.position }

    private var scrubber: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let total = max(engine.duration, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.35)).frame(width: width * min(1, engine.buffered / total))
                Capsule().fill(.white).frame(width: width * min(1, engine.position / total))
                if let target = chrome.scrubTarget {
                    Rectangle().fill(.white).frame(width: 4, height: 34).offset(x: width * min(1, target / total) - 2)
                }
            }
            .frame(height: 10)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 34)
    }

    // MARK: Next Episode

    private var nextButtons: some View {
        HStack(spacing: 24) {
            ForEach(chrome.nextActions) { item in
                Button { item.action?() } label: {
                    Label(item.title, systemImage: item.symbol ?? "play.fill").font(.system(size: 28, weight: .semibold))
                }
                .disabled(item.action == nil)
            }
        }
        .padding(.trailing, 90)
        .padding(.bottom, barShowing ? 230 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.25), value: barShowing)
    }

    // MARK: Menus (swipe down)

    private var panel: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                ForEach(chrome.menus) { menu in
                    Button {
                        if let action = menu.action { action() } else { chrome.selectedMenu = menu.title }
                    } label: {
                        Label(menu.title, systemImage: menu.symbol).font(.system(size: 26, weight: .semibold))
                    }
                    .buttonStyle(TVPanelTabStyle(selected: chrome.selectedMenu == menu.title))
                }
            }
            if let menu = chrome.menus.first(where: { $0.title == chrome.selectedMenu }), menu.action == nil {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(menu.items) { item in
                            if let action = item.action {
                                Button(action: action) {
                                    HStack(spacing: 14) {
                                        Image(systemName: "checkmark").opacity(item.isOn ? 1 : 0)
                                        Text(item.title).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.system(size: 26))
                                }
                                .buttonStyle(TVPanelRowStyle())
                            } else {
                                Text(item.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(TVMetrics.secondaryText)
                                    .padding(.top, 12).padding(.leading, 20)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                .frame(maxHeight: 560)
            }
        }
        .padding(40)
        .frame(maxWidth: 1300, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .padding(.top, 50)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 30) {
            Text(message).font(.system(size: 32, weight: .semibold)).multilineTextAlignment(.center)
            Button("Close") { chrome.onClose() }
        }
        .padding(60)
        .frame(maxWidth: 900)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
    }

    // MARK: Picture subtitles

    @ViewBuilder private func embeddedImages(in rect: CGRect) -> some View {
        if case let .images(images)? = engine.embeddedSubtitle {
            ForEach(images.indices, id: \.self) { index in
                let frame = images[index].frame
                Image(decorative: images[index].image, scale: 1)
                    .resizable()
                    .frame(width: rect.width * frame.width, height: rect.height * frame.height)
                    .position(x: rect.minX + rect.width * frame.midX, y: rect.minY + rect.height * frame.midY)
            }
        }
    }

    private func videoRect(_ size: CGSize) -> CGRect {
        let video = engine.presentationSize
        guard video.width > 0, video.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / video.width, size.height / video.height)
        let fitted = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}

/// A tab in the menus panel: lit when focused, a soft fill when it's the one showing.
private struct TVPanelTabStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 26).padding(.vertical, 14)
            .foregroundStyle(focused ? .black : .white)
            .background(Capsule().fill(focused ? .white : .white.opacity(selected ? 0.25 : 0.08)))
            .scaleEffect(focused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct TVPanelRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(focused ? .black : .white)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(focused ? .white : .clear))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
