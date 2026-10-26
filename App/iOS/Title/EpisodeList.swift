import AMDBCore
import AMDBKit
import SwiftUI

struct EpisodeList: View {
    let model: TitleModel
    @Environment(AppModel.self) private var app
    @Environment(OfflineDownloader.self) private var downloader
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var confirmRemove = false

    var body: some View {
        let seasons = model.detail?.seasons ?? []
        VStack(alignment: .leading, spacing: 16) {
            // iPhone: the season name on its own line, the buttons under it (they'd wrap beside it).
            if sizeClass == .compact {
                VStack(alignment: .leading, spacing: 12) {
                    seasonMenu(seasons)
                    if let season = model.selectedSeason {
                        HStack(spacing: 10) {
                            downloadSeasonButton(season)
                            seasonButton(season)
                        }
                        .lineLimit(1)
                    }
                }
            } else {
                HStack {
                    seasonMenu(seasons)
                    Spacer()
                    if let season = model.selectedSeason {
                        downloadSeasonButton(season)
                        seasonButton(season)
                    }
                }
                .lineLimit(1)
            }
            onDeviceRow
            ForEach(model.episodes) { episode in
                if let season = model.selectedSeason {
                    EpisodeRow(model: model, season: season, episode: episode, next: nextEpisode(after: episode.number, in: season))
                        .id(EpisodeKey(tmdbID: model.item.tmdbID, season: season, episode: episode.number))
                }
            }
        }
        .padding(.horizontal, Metrics.gutter(sizeClass))
    }

    private func seasonMenu(_ seasons: [SeasonSummary]) -> some View {
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
    }

    /// Every episode of this show saved on this device (any season), finished or still downloading.
    private var showDownloads: [DownloadRecord] {
        let tmdbID = model.item.tmdbID
        let libraryIDs = Set(app.library.matching(tmdbID: tmdbID).map(\.id))
        return app.downloads.records.filter { record in
            (record.tmdbID == tmdbID && record.kind == .tv) || libraryIDs.contains(record.fileID)
        }
    }

    /// "8 episodes on this device · 12.4 GB" with Remove Downloads, for the whole show.
    @ViewBuilder private var onDeviceRow: some View {
        let records = showDownloads
        let finished = records.filter { if case .done = $0.state { true } else { false } }
        if !records.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white.opacity(0.6))
                Text(onDeviceSummary(finished: finished.count, total: records.count))
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label(sizeClass == .compact ? "Remove" : "Remove Downloads", systemImage: "trash")
                }
                .buttonStyle(.glassPill)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("Remove all downloads of \(model.item.title) from this device")
            }
            .alert("Remove \(records.count) downloaded episode\(records.count == 1 ? "" : "s") of \(model.item.title)?",
                   isPresented: $confirmRemove) {
                Button("Cancel", role: .cancel) {}
                Button("Remove from This Device", role: .destructive) {
                    let ids = records.map(\.fileID)
                    Task {
                        for id in ids { await downloader.cancel(fileID: id) }
                        router.toast = "Removed \(ids.count) download\(ids.count == 1 ? "" : "s")"
                    }
                }
            } message: {
                Text("Frees \(Format.bytes(finished.compactMap { downloader.size(fileID: $0.fileID) }.reduce(0, +))) on this device. The episodes stay in your put.io.")
            }
        }
    }

    private func onDeviceSummary(finished: Int, total: Int) -> String {
        let bytes = showDownloads.compactMap { downloader.size(fileID: $0.fileID) }.reduce(Int64(0), +)
        var text = "\(finished) episode\(finished == 1 ? "" : "s") on this device"
        if total > finished { text += " · \(total - finished) downloading" }
        if bytes > 0 { text += " · \(Format.bytes(bytes))" }
        return text
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
            // Every episode is already in put.io: nothing to get (it comes back if one goes missing).
            if !model.isSeasonInPutio(season) {
                getSeasonButton(season)
            }
        }
    }

    private func getSeasonButton(_ season: Int) -> some View {
            Button {
                guard let query = model.query(season: season) else {
                    router.toast = model.queryUnavailableMessage
                    return
                }
                router.versions = VersionsRequest(query: query, target: model.target(season: season), playNow: [])
            } label: { Label("Get season", systemImage: "square.stack.3d.down.right") }
            .buttonStyle(.glassPill)
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
        let library = app.library
        let files = library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode.number)
        let watched = files.max { library.resumeSeconds(for: $0) < library.resumeSeconds(for: $1) }
        let resume = watched.map { library.resumeSeconds(for: $0) } ?? 0
        // Watched to the end (and not started again): a ✓ and a full bar.
        let finished = resume < 30 && files.contains(where: library.isWatched)
        let estimate = episode.runtimeMinutes.map { $0 * 60 }
        let fraction = watched.flatMap { library.watchedFraction(for: $0, estimatedLength: estimate) }
        let left = watched.flatMap { library.remainingSeconds(for: $0, estimatedLength: estimate) }
        HStack(alignment: .center, spacing: regular ? 14 : 10) {
            // Started episodes: time left on the picture and a bar under it showing how much is watched.
            VStack(spacing: 5) {
                RemoteImage(path: episode.stillPath, size: "w300", seed: "\(model.item.title) \(episode.number)")
                    .frame(width: regular ? 220 : 104, height: regular ? 124 : 58)
                    .overlay(alignment: .bottomLeading) {
                        if resume >= 30, regular || left != nil {
                            Label(left.map(Format.left) ?? "Resume \(Format.clock(resume))", systemImage: "play.fill")
                                .font(.caption2.weight(.bold)).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.6), in: Capsule()).padding(6)
                        } else if finished {
                            WatchedBadge().padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) { if !regular { downloadBadge } }
                if let fraction {
                    WatchedBar(fraction: fraction, height: regular ? 4 : 3).frame(width: regular ? 220 : 104)
                } else if finished {
                    WatchedBar(fraction: 1, height: regular ? 4 : 3).frame(width: regular ? 220 : 104)
                }
            }
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
