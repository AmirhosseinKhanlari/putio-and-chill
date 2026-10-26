import AMDBCore
import AMDBKit
import SwiftUI

/// "Can't decide?" — a full-screen, cinematic random pick for a mood. Shuffle with the dice or a swipe;
/// "Not feeling it?" offers other matches for the same mood.
struct SurprisePage: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: SurpriseModel?
    @State private var kind: MediaKind = .movie
    @State private var mood: Mood = .anything
    @State private var detail: TitleDetail?
    @State private var ratings: Ratings?
    @State private var shuffles = 0

    private var regular: Bool { sizeClass != .compact }

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            ZStack(alignment: .bottomLeading) {
                Theme.background.ignoresSafeArea()
                if let pick = model?.pick {
                    backdrop(pick, portrait: portrait)
                        .id(pick.id)
                        .transition(.opacity)
                }
                scrims
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    moodChips.padding(.top, 14)
                    Spacer(minLength: 20)
                    content
                    alternativesStrip.padding(.top, regular ? 28 : 20)
                }
                .padding(.bottom, regular ? 28 : 12)
            }
            .animation(.smooth(duration: 0.45), value: model?.pick?.id)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.width < -80, abs(value.translation.height) < 120 { shuffle() }
            })
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(weight: .medium), trigger: shuffles)
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            model = SurpriseModel(catalog: catalog)
            await model?.roll(kind: kind, mood: mood)
        }
        .task(id: model?.pick?.id) { await loadDetail() }
        .onChange(of: kind) { shuffle() }
        .onChange(of: mood) { shuffle() }
    }

    // MARK: Layers

    private func backdrop(_ pick: CatalogItem, portrait: Bool) -> some View {
        // Phones held upright get the poster; everything else the wide still.
        let usePoster = portrait && !regular
        return RemoteImage(path: usePoster ? (pick.posterPath ?? pick.backdropPath) : (pick.backdropPath ?? pick.posterPath),
                           size: usePoster ? "w780" : "w1280", seed: pick.title, alignment: .top)
            .ignoresSafeArea()
            .scaleEffect(model?.isRolling == true ? 1.04 : 1)
            .blur(radius: model?.isRolling == true ? 12 : 0)
            .animation(.easeInOut(duration: 0.35), value: model?.isRolling)
    }

    private var scrims: some View {
        ZStack {
            LinearGradient(colors: [Theme.background.opacity(regular ? 0.85 : 0.2), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.22),
                                   .init(color: .clear, location: 0.4), .init(color: Theme.background.opacity(0.92), location: 0.78),
                                   .init(color: Theme.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44).glassCapsule()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Spacer()
            if regular {
                Text("SURPRISE ME").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.8))
                Spacer()
            }
            kindToggle
        }
        .padding(.horizontal, Metrics.gutter(sizeClass))
        .padding(.top, 8)
    }

    private var kindToggle: some View {
        HStack(spacing: 2) {
            ForEach([MediaKind.movie, .tv], id: \.self) { option in
                Button { withAnimation(.snappy) { kind = option } } label: {
                    Text(option == .movie ? "Movies" : "Series")
                        .font(.footnote.weight(.semibold))
                        .fixedSize()
                        .foregroundStyle(kind == option ? .black : .white)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background { if kind == option { Capsule().fill(.white) } }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(kind == option ? .isSelected : [])
            }
        }
        .padding(4)
        .glassCapsule()
    }

    private var moodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Mood.allCases) { option in
                    Button { withAnimation(.snappy) { mood = option } } label: {
                        HStack(spacing: 6) {
                            Text(option.emoji)
                            Text(option.title).font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 16).frame(height: 40)
                        .foregroundStyle(mood == option ? .black : .white)
                        .background { if mood == option { Capsule().fill(.white) } }
                        .glassCapsule()
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(mood == option ? .isSelected : [])
                }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
        }
    }

    // MARK: Pick

    @ViewBuilder private var content: some View {
        if let model, let pick = model.pick {
            VStack(alignment: .leading, spacing: regular ? 14 : 10) {
                Text("TONIGHT'S PICK · \(mood.emoji) \(mood.title.uppercased())")
                    .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                titleBlock(pick)
                MetaLine(item: pick, detail: detail, ratings: ratings)
                if let genres = detail?.genres, !genres.isEmpty {
                    Text(genres.prefix(4).joined(separator: " · ")).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                let overview = detail?.item.overview.isEmpty == false ? detail!.item.overview : pick.overview
                if !overview.isEmpty {
                    Text(overview).font(regular ? .body : .callout).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(regular ? 4 : 3).frame(maxWidth: 620, alignment: .leading)
                }
                actions(pick)
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .id(pick.id)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
        } else if model?.isEmpty == true {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing matched that mood").font(.title2.weight(.semibold))
                Text("Try another mood or switch between movies and series.").foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
        } else {
            HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private func titleBlock(_ pick: CatalogItem) -> some View {
        if let logo = detail?.logoPath {
            RemoteImage(path: logo, size: "w500", seed: pick.title, contentMode: .fit, alignment: .leading)
                .frame(maxWidth: regular ? 460 : 280, maxHeight: regular ? 150 : 96, alignment: .leading)
                .accessibilityLabel(pick.title)
        } else {
            Text(pick.title.uppercased())
                .font(.system(size: regular ? 60 : 36, weight: .ultraLight)).tracking(regular ? 5 : 2)
                .lineLimit(2).minimumScaleFactor(0.6)
                .frame(maxWidth: regular ? 820 : 360, alignment: .leading)
        }
    }

    private func actions(_ pick: CatalogItem) -> some View {
        HStack(spacing: 12) {
            Button { open(pick) } label: { Label("Watch This", systemImage: "play.fill") }
                .buttonStyle(.primaryPill)
            MyListButton(item: pick, iconOnly: !regular)
            Spacer(minLength: 0)
            shuffleButton
        }
        .padding(.top, 6)
    }

    private var shuffleButton: some View {
        Button { shuffle() } label: {
            VStack(spacing: 4) {
                Image(systemName: "dice.fill")
                    .font(.system(size: regular ? 26 : 22, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: regular ? 64 : 54, height: regular ? 64 : 54)
                    .background(.white, in: Circle())
                    .rotationEffect(.degrees(Double(shuffles) * 360))
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: shuffles)
                Text("Shuffle").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .disabled(model?.isRolling == true)
        .accessibilityLabel("Shuffle")
    }

    @ViewBuilder private var alternativesStrip: some View {
        if let model, !model.alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not feeling it?").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                Shelf {
                    HStack(spacing: 12) {
                        ForEach(model.alternatives) { item in
                            Button { withAnimation(.smooth(duration: 0.45)) { model.choose(item) } } label: {
                                ZStack(alignment: .bottomLeading) {
                                    RemoteImage(path: item.backdropPath, size: "w300", seed: item.title)
                                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                                    Text(item.title).font(.caption.weight(.semibold)).lineLimit(1).padding(8)
                                }
                                .frame(width: regular ? 220 : 160, height: regular ? 124 : 90)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
                            }
                            .buttonStyle(.lift)
                            .accessibilityLabel(item.title)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                }
            }
        }
    }

    // MARK: Actions

    private func shuffle() {
        guard let model, !model.isRolling else { return }
        shuffles += 1
        Task {
            await model.roll(kind: kind, mood: mood)
        }
    }

    private func loadDetail() async {
        detail = nil
        ratings = nil
        guard let pick = model?.pick, let catalog = app.catalog else { return }
        guard let loaded = try? await catalog.detail(pick.mediaType, id: pick.tmdbID), model?.pick?.id == pick.id else { return }
        withAnimation(.easeOut(duration: 0.25)) { detail = loaded }
        if let fetched = await app.ratings(imdbID: loaded.imdbID, tmdbID: pick.tmdbID, kind: pick.mediaType),
           model?.pick?.id == pick.id {
            ratings = fetched
        }
    }

    private func open(_ pick: CatalogItem) {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            router.open(pick)
        }
    }
}
