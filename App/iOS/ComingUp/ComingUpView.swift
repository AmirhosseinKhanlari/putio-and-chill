import AMDBCore
import AMDBKit
import SwiftUI

/// Coming Up: Movies (box office, in cinemas, coming soon) and TV (your shows' next episodes by day, premieres,
/// returning this week).
struct ComingUpView: View {
    enum Section: String, CaseIterable { case movies = "Movies", tv = "TV" }

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: ComingUpModel?
    @State private var section: Section = .movies

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Coming Up").font(.system(size: sizeClass == .compact ? 34 : 48, weight: .ultraLight)).tracking(3)
                    Picker("Show", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
                .padding(.top, 12)

                if let model {
                    if section == .movies { movies(model) } else { shows(model) }
                    if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .padding(.bottom, 120)
        }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: section) {
            if model == nil, let catalog = app.catalog { model = ComingUpModel(app: app, catalog: catalog) }
            if section == .movies { await model?.loadMovies() } else { await model?.loadShows() }
        }
    }

    // MARK: Movies

    @ViewBuilder private func movies(_ model: ComingUpModel) -> some View {
        if !model.boxOffice.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header("Box Office This Weekend", note: "US · Trakt")
                ForEach(model.boxOffice) { BoxOfficeRow(item: $0) }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
        }
        if !model.inCinemas.isEmpty {
            CatalogRowView(row: CatalogRow(id: "cinemas", title: "In Cinemas Now", items: model.inCinemas))
        }
        if !model.comingSoon.isEmpty { DatedRow(title: "Coming Soon to Cinemas", items: model.comingSoon) }
    }

    // MARK: TV

    @ViewBuilder private func shows(_ model: ComingUpModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Your Upcoming Episodes", note: "Shows in put.io and My List")
            if model.yourEpisodes.isEmpty, !model.isLoading {
                Text("Nothing scheduled in the next 30 days for your shows.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(model.yourEpisodes) { day in
                Text(day.label.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 6)
                ForEach(day.episodes) { EpisodeRow(episode: $0) }
            }
        }
        .padding(.horizontal, Metrics.gutter(sizeClass))
        if !model.premieringSoon.isEmpty { DatedRow(title: "Premiering Soon", items: model.premieringSoon) }
        if !model.returning.isEmpty {
            CatalogRowView(row: CatalogRow(id: "returning", title: "Returning This Week", items: model.returning))
        }
    }

    private func header(_ title: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BoxOfficeRow: View {
    let item: ComingUpModel.BoxOfficeItem
    @Environment(Router.self) private var router

    var body: some View {
        Button { router.open(item.item) } label: {
            HStack(spacing: 14) {
                Text("\(item.entry.rank)").font(.title2.weight(.bold).monospacedDigit()).frame(width: 34)
                RemoteImage(path: item.item.posterPath, size: "w185", seed: item.item.title)
                    .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.item.title).font(.headline).lineLimit(1)
                    Text([item.item.year.map(String.init), item.entry.revenueText.map { "\($0) weekend" }].compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EpisodeRow: View {
    let episode: UpcomingEpisode
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 4) {
            Button { router.open(episode.show) } label: {
                HStack(spacing: 12) {
                    RemoteImage(path: episode.stillPath ?? episode.show.backdropPath, size: "w300", seed: episode.show.title)
                        .frame(width: 112, height: 63).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.show.title).font(.headline).lineLimit(1)
                        Text("S\(episode.season) E\(episode.episode) · \(episode.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            EpisodeBell(show: episode.show)
        }
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Bell: notify me when this show has a new episode.
struct EpisodeBell: View {
    let show: CatalogItem
    @Environment(AppModel.self) private var app
    @State private var denied = false

    var body: some View {
        let on = app.episodeAlerts.isFollowing(show.tmdbID)
        Button {
            Task {
                if !on, !(await EpisodeAlertScheduler.requestPermission()) { denied = true; return }
                await app.episodeAlerts.setFollowing(show, !on)
                if !on, !app.settings.episodeAlerts {
                    var settings = app.settings
                    settings.episodeAlerts = true
                    app.updateSettings(settings)
                }
                await EpisodeAlertScheduler.reschedule(app)
            }
        } label: {
            Image(systemName: on ? "bell.fill" : "bell")
                .font(.title3)
                .foregroundStyle(on ? Theme.okay : .white.opacity(0.7))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .symbolEffect(.bounce, value: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Stop new-episode alerts for \(show.title)" : "Notify me about new episodes of \(show.title)")
        .alert("Notifications are off", isPresented: $denied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on notifications for Putio & Chill in the Settings app to get new-episode alerts.")
        }
    }
}

/// Posters with their date underneath ("Oct 24").
private struct DatedRow: View {
    let title: String
    let items: [DatedItem]
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            Shelf {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { dated in
                        Button { router.open(dated.item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                PosterCard(item: dated.item, width: Metrics.poster(sizeClass))
                                if let date = ComingUpModel.shortDate(dated.date) {
                                    Label(date, systemImage: "calendar").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                                }
                            }
                        }
                        .buttonStyle(.lift)
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}
