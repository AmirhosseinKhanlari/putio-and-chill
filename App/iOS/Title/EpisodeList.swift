import AMDBCore
import AMDBKit
import SwiftUI

struct EpisodeList: View {
    let model: TitleModel
    @Environment(AppModel.self) private var app
    @Environment(OfflineDownloader.self) private var downloader
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let seasons = model.detail?.seasons ?? []
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Menu {
                    ForEach(seasons, id: \.number) { season in
                        Button(season.name) { Task { await model.selectSeason(season.number) } }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(seasons.first { $0.number == model.selectedSeason }?.name ?? "Season").font(.title3.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption.bold())
                    }
                    .foregroundStyle(.white)
                }
                Spacer()
                if let season = model.selectedSeason {
                    downloadSeasonButton(season)
                    seasonButton(season)
                }
            }
            ForEach(model.episodes) { episode in
                if let season = model.selectedSeason {
                    EpisodeRow(model: model, season: season, episode: episode, next: nextEpisode(after: episode.number, in: season))
                }
            }
        }
        .padding(.horizontal, Metrics.gutter(sizeClass))
    }

    /// Saves every episode of the season that's already in put.io to this device. Says "Season downloaded" only when
    /// every episode of the season is on the device.
    @ViewBuilder private func downloadSeasonButton(_ season: Int) -> some View {
        let inPutio = model.episodes.compactMap { app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: $0.number).first }
        let states = inPutio.map { app.downloads.record(fileID: $0.id)?.state }
        let downloaded = states.filter { if case .done? = $0 { true } else { false } }.count
        let active = states.filter { if case .downloading? = $0 { true } else if case .queued? = $0 { true } else { false } }.count
        // Not on the device yet (never downloaded, or a download that failed).
        let missing = zip(inPutio, states).filter { _, state in
            switch state { case nil, .failed?: true; default: false }
        }.map(\.0)
        let status = SeasonDownloadStatus.of(total: model.episodes.count, inPutio: inPutio.count, downloaded: downloaded,
                                             active: active)
        if !inPutio.isEmpty {
            Button {
                Task { for entry in missing { await downloader.start(entry) } }
            } label: {
                switch status {
                case let .download(count, wholeSeason):
                    Label(wholeSeason ? "Download season" : "Download \(count) episode\(count == 1 ? "" : "s")",
                          systemImage: "arrow.down.to.line")
                case let .downloading(count):
                    Label("Downloading \(count)…", systemImage: "arrow.down.circle")
                case .seasonDownloaded:
                    Label("Season downloaded", systemImage: "checkmark.circle.fill")
                case let .partial(done, total):
                    Label("\(done) of \(total) downloaded", systemImage: "checkmark.circle")
                }
            }
            .buttonStyle(.glassPill)
            .disabled(missing.isEmpty || !OfflineDownloader.isSupported)
            .accessibilityHint(OfflineDownloader.isSupported ? "Saves \(missing.count) episodes for offline viewing" : "Downloads need a real device")
        }
    }

    @ViewBuilder private func seasonButton(_ season: Int) -> some View {
        switch model.action(season: season, episode: nil) {
        case let .downloading(transfer):
            DownloadStatus(transfer: transfer)
        default:
            Button {
                guard let query = model.query(season: season) else { return }
                router.versions = VersionsRequest(query: query, target: model.target(season: season), playNow: [])
            } label: { Label("Get season", systemImage: "square.stack.3d.down.right") }
            .buttonStyle(.glassPill)
        }
    }

    private func nextEpisode(after number: Int, in season: Int) -> NextEpisode? {
        guard model.episodes.contains(where: { $0.number == number + 1 }) else { return nil }
        return NextEpisode(query: model.query(season: season, episode: number + 1),
                           target: model.target(season: season, episode: number + 1),
                           label: "S\(season) · E\(number + 1)")
    }
}

private struct EpisodeRow: View {
    let model: TitleModel
    let season: Int
    let episode: Episode
    let next: NextEpisode?
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let regular = sizeClass != .compact
        let resume = app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode.number)
            .map { app.library.resumeSeconds(for: $0) }.max() ?? 0
        HStack(alignment: .center, spacing: regular ? 14 : 10) {
            RemoteImage(path: episode.stillPath, size: "w300", seed: "\(model.item.title) \(episode.number)")
                .frame(width: regular ? 220 : 104, height: regular ? 124 : 58)
                .overlay(alignment: .bottomLeading) {
                    if resume >= 30 {
                        Label(Format.clock(resume), systemImage: "play.fill").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.6), in: Capsule()).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) { if !regular { downloadBadge } }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.number). \(episode.name)").font(regular ? .headline : .subheadline.weight(.semibold))
                    .lineLimit(regular ? 1 : 2)
                HStack(spacing: 10) {
                    if let score = model.episodeRatings[episode.number] {
                        IMDbScore(rating: score.rating).font(.caption.weight(.semibold)).fixedSize()
                    }
                    if let runtime = Format.runtime(episode.runtimeMinutes) {
                        Text(runtime).font(.caption).foregroundStyle(.white.opacity(0.55)).fixedSize()
                    }
                    if isBestOfSeason {
                        Group {
                            if regular {
                                Label("Best of season", systemImage: "star.fill").font(.caption2.weight(.semibold)).lineLimit(1)
                            } else {
                                Image(systemName: "star.fill").font(.caption2)
                            }
                        }
                        .foregroundStyle(Color(red: 0.96, green: 0.77, blue: 0.09))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Best of season")
                    }
                }
                if regular, !episode.overview.isEmpty {
                    Text(episode.overview).font(.footnote).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
            }
            Spacer(minLength: regular ? 8 : 4)
            EpisodeActionButton(model: model, season: season, episode: episode.number, next: next)
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    /// On iPhone the Download button lives in the ⋯ menu; its state shows here.
    @ViewBuilder private var downloadBadge: some View {
        let entries = app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode.number)
        let states = entries.compactMap { app.downloads.record(fileID: $0.id)?.state }
        if states.contains(where: { if case .done = $0 { true } else { false } }) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, Theme.good)
                .padding(5).accessibilityLabel("Downloaded")
        } else if let progress = states.compactMap({ if case let .downloading(value) = $0 { value } else { nil } }).first {
            ProgressRing(progress: progress, lineWidth: 2.5).frame(width: 16, height: 16).padding(6)
                .background(.black.opacity(0.5), in: Circle()).padding(3).accessibilityLabel("Downloading")
        }
    }

    /// Highest IMDb score in a season with at least three rated episodes.
    private var isBestOfSeason: Bool {
        let scores = model.episodeRatings
        guard scores.count >= 3, let mine = scores[episode.number]?.rating else { return false }
        return scores.values.allSatisfy { $0.rating <= mine } && scores.values.filter { $0.rating == mine }.count == 1
    }
}
