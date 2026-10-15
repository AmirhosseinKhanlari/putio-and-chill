import AMDBCore
import AMDBKit
import SwiftUI

/// Cast / crew member: round portrait, details, biography, then what they're known for and everything else.
struct TVPersonView: View {
    let personID: Int
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var person: PersonDetail?
    @State private var failed = false
    /// The first title (Known For, else Movies) is selected when the page opens.
    @FocusState private var focusedItem: String?

    var body: some View {
        ScrollView(.vertical) {
            if let person {
                VStack(alignment: .leading, spacing: 40) {
                    HStack(alignment: .top, spacing: 60) {
                        ZStack {
                            Color.white.opacity(0.1)
                            RemoteImage(path: person.profilePath, size: "h632", seed: person.name, alignment: .top)
                        }
                        .frame(width: 320, height: 320)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 18) {
                            Text(person.name).font(.system(size: 72, weight: .bold)).lineLimit(2)
                            Text(details(person)).font(.system(size: 24, weight: .medium)).foregroundStyle(TVMetrics.secondaryText)
                            if !person.biography.isEmpty {
                                // Just text: focus goes from the header straight to the titles.
                                Text(person.biography).font(.system(size: 24)).lineLimit(7).multilineTextAlignment(.leading)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(maxWidth: 1200, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, TVMetrics.edge)
                    .padding(.top, 40)

                    if !person.knownFor.isEmpty {
                        TVShelf(title: "Known For") {
                            ForEach(person.knownFor) { item in
                                TVPosterButton(item: item) { router.open(item) }.focused($focusedItem, equals: item.id)
                            }
                        }
                    }
                    let movies = person.credits.filter { $0.mediaType == .movie }
                    let shows = person.credits.filter { $0.mediaType == .tv }
                    if !movies.isEmpty {
                        TVShelf(title: "Movies", trailing: AnyView(count(movies.count))) {
                            ForEach(movies) { item in
                                TVPosterButton(item: item, badge: item.year.map(String.init)) { router.open(item) }
                                    .focused($focusedItem, equals: "movies-" + item.id)
                            }
                        }
                    }
                    if !shows.isEmpty {
                        TVShelf(title: "TV Shows", trailing: AnyView(count(shows.count))) {
                            ForEach(shows) { item in TVPosterButton(item: item, badge: item.year.map(String.init)) { router.open(item) } }
                        }
                    }
                }
                .padding(.bottom, 90)
            } else if failed {
                Text("Couldn't load this person.").foregroundStyle(TVMetrics.secondaryText).padding(TVMetrics.edge)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
            }
        }
        .defaultFocus($focusedItem, firstTitle, priority: .userInitiated)
        .onChange(of: person?.id) { _, _ in
            // When the page has loaded, put focus on the first title (not up on the tab bar).
            if let firstTitle { Task { try? await Task.sleep(for: .milliseconds(150)); focusedItem = firstTitle } }
        }
        .tvPageBackground()
        .task {
            guard person == nil, let catalog = app.catalog else { return }
            do { person = try await catalog.person(id: personID) } catch { failed = true }
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private var firstTitle: String? {
        guard let person else { return nil }
        if let first = person.knownFor.first { return first.id }
        return person.credits.first { $0.mediaType == .movie }.map { "movies-" + $0.id }
    }

    private func details(_ person: PersonDetail) -> String {
        let born = person.birthday.flatMap { $0.split(separator: "-").first.map { "Born \($0)" } }
        return [person.department, born, person.placeOfBirth].compactMap { $0 }.joined(separator: " · ")
    }

    private func count(_ value: Int) -> some View {
        Text("\(value)").font(.system(size: 22)).foregroundStyle(TVMetrics.secondaryText)
    }
}

/// A film series (TMDB collection), in release order.
struct TVCollectionView: View {
    let collectionID: Int
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var collection: CollectionDetail?
    @State private var failed = false

    var body: some View {
        ZStack {
            TVBackdrop(path: collection?.backdropPath, seed: collection?.name ?? "collection")
            ScrollView(.vertical) {
                if let collection {
                    VStack(alignment: .leading, spacing: 20) {
                        Spacer(minLength: 0)
                        Text(collection.name).font(.system(size: 76, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                        Text(meta(collection)).font(.system(size: 24, weight: .medium)).foregroundStyle(TVMetrics.secondaryText)
                        if !collection.overview.isEmpty {
                            Text(collection.overview).font(.system(size: 26)).foregroundStyle(.white.opacity(0.86)).lineLimit(3)
                                .frame(maxWidth: 1000, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, TVMetrics.edge)
                    .padding(.bottom, 20)
                    .containerRelativeFrame(.vertical, alignment: .bottomLeading) { height, _ in height * 0.52 }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    TVShelf(title: "In Order") {
                        ForEach(Array(collection.parts.enumerated()), id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: 12) {
                                TVPosterButton(item: item) { router.open(item) }
                                Text("\(index + 1). \(item.title)").font(.system(size: 21, weight: .semibold)).lineLimit(1)
                                if let year = item.year { Text(String(year)).font(.system(size: 19)).foregroundStyle(TVMetrics.secondaryText) }
                            }
                            .frame(width: TVMetrics.poster.width, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 60)
                } else if failed {
                    Text("Couldn't load this collection.").padding(TVMetrics.edge)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 300)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard collection == nil, let catalog = app.catalog else { return }
            do { collection = try await catalog.collection(id: collectionID) } catch { failed = true }
        }
    }

    private func meta(_ collection: CollectionDetail) -> String {
        let years = collection.parts.compactMap(\.year)
        let span = years.min().map { first in years.max().map { $0 == first ? "\(first)" : "\(first)–\($0)" } ?? "\(first)" }
        let owned = collection.parts.filter { !app.library.matching(tmdbID: $0.tmdbID).isEmpty }.count
        return ["Collection", "\(collection.parts.count) movies", span, owned > 0 ? "\(owned) in put.io" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Surprise Me: pick Movies or Series and a mood; one big pick with its actions, Shuffle, and alternatives.
struct TVSurpriseView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SurpriseModel?
    @State private var kind: MediaKind = .movie
    @State private var mood: Mood = .anything

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 36) {
                ZStack(alignment: .top) {
                    if let pick = model?.pick {
                        TVFeatured(item: pick).id(pick.id)
                    } else {
                        Color.clear.containerRelativeFrame(.vertical) { height, _ in height * 0.84 }
                            .overlay {
                                if model?.isEmpty == true {
                                    Text("Nothing matched. Try another mood.").foregroundStyle(TVMetrics.secondaryText)
                                } else {
                                    ProgressView()
                                }
                            }
                    }
                    controls
                }
                if let alternatives = model?.alternatives, !alternatives.isEmpty {
                    TVShelf(title: "Not feeling it?") {
                        ForEach(alternatives) { item in
                            TVWideCard(title: item.title, subtitle: item.year.map(String.init), imagePath: item.backdropPath) {
                                withAnimation(.easeInOut(duration: 0.35)) { model?.choose(item) }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 90)
        }
        .ignoresSafeArea(edges: .top)
        .tvPageBackground()
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let surprise = SurpriseModel(catalog: catalog)
            model = surprise
            await surprise.roll(kind: kind, mood: mood)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Text("Surprise Me").font(.system(size: 40, weight: .bold)).padding(.trailing, 24)
                kindChip("Movies", .movie)
                kindChip("Series", .tv)
                Spacer()
                Button { roll() } label: {
                    Label(model?.isRolling == true ? "Shuffling…" : "Shuffle", systemImage: "shuffle").fixedSize()
                }
                .tvPill()
            }
            HStack(spacing: 14) {
                ForEach(Mood.allCases) { option in
                    Button { mood = option; roll() } label: { Text(option.title).lineLimit(1).fixedSize() }
                        .tvChip(selected: mood == option)
                }
            }
        }
        .padding(.horizontal, TVMetrics.edge)
        .padding(.top, 60)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Keeps the chips readable over bright art.
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
        .focusSection()
    }

    private func kindChip(_ title: String, _ value: MediaKind) -> some View {
        Button(title) { kind = value; roll() }.tvChip(selected: kind == value)
    }

    private func roll() {
        guard let model, !model.isRolling else { return }
        Task { await model.roll(kind: kind, mood: mood) }
    }
}

/// IMDb Top 250: ranked list on the left, the focused title's art behind it.
struct TVChartView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var kind: MediaKind = .movie
    @State private var models: [MediaKind: ChartModel] = [:]
    @FocusState private var focused: String?

    var body: some View {
        let model = models[kind]
        let backdrop = focused.flatMap { model?.items[$0] }?.backdropPath ?? model?.entries.first.flatMap { model?.items[$0.id] }?.backdropPath
        ZStack {
            TVBackdrop(path: backdrop, seed: "top250").animation(.easeInOut(duration: 0.4), value: backdrop)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 26) {
                        TVPageHeader(title: "IMDb Top 250", subtitle: model.map { "\($0.entries.count) titles, ranked by IMDb users · Lists from Trakt" })
                        HStack(spacing: 16) {
                            Button("Movies") { kind = .movie }.tvChip(selected: kind == .movie)
                            Button("TV Shows") { kind = .tv }.tvChip(selected: kind == .tv)
                        }
                        .focusSection()
                    }
                    .padding(.bottom, 16)

                    if !app.hasCharts {
                        Text("Top 250 needs a Trakt client ID in Config/Secrets.xcconfig.").foregroundStyle(TVMetrics.secondaryText)
                    } else if let model {
                        if model.isLoading, model.entries.isEmpty { ProgressView().padding(.top, 40) }
                        if model.error != nil { Text("Couldn't load the chart.").foregroundStyle(TVMetrics.secondaryText) }
                        ForEach(model.entries) { entry in row(entry, model: model) }
                    }
                }
                .padding(TVMetrics.edge)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: kind) {
            guard app.hasCharts, let catalog = app.catalog else { return }
            let model = models[kind] ?? ChartModel(chart: kind == .tv ? .top250TV : .top250Movies, app: app, catalog: catalog)
            models[kind] = model
            await model.load()
            if let first = model.entries.first { await model.item(for: first) }
        }
    }

    private func row(_ entry: ChartEntry, model: ChartModel) -> some View {
        let item = model.items[entry.id]
        let owned = entry.tmdbID.map { !app.library.matching(tmdbID: $0).isEmpty } ?? false
        return Button {
            Task { if let item = await model.item(for: entry) ?? item { router.open(item) } }
        } label: {
            HStack(spacing: 26) {
                Text("\(entry.rank)").font(.system(size: 34, weight: .bold).monospacedDigit()).frame(width: 80, alignment: .trailing)
                RemoteImage(path: item?.posterPath, size: "w185", seed: entry.title)
                    .frame(width: 64, height: 96).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title).font(.system(size: 27, weight: .semibold)).lineLimit(1)
                    Text([entry.year.map(String.init), owned ? "In put.io" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 21)).opacity(0.7)
                }
                Spacer(minLength: 0)
            }
        }
        .tvRow()
        .focused($focused, equals: entry.id)
        .task { await model.item(for: entry) }
    }
}
