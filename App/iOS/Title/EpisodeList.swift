import AMDBCore
import AMDBKit
import SwiftUI

struct EpisodeList: View {
    let model: TitleModel
    @Environment(AppModel.self) private var app
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
        HStack(alignment: .center, spacing: 14) {
            RemoteImage(path: episode.stillPath, size: "w300", seed: "\(model.item.title) \(episode.number)")
                .frame(width: regular ? 220 : 128, height: regular ? 124 : 72)
                .overlay(alignment: .bottomLeading) {
                    if resume >= 30 {
                        Label(Format.clock(resume), systemImage: "play.fill").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.6), in: Capsule()).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.number). \(episode.name)").font(.headline).lineLimit(1)
                if let runtime = Format.runtime(episode.runtimeMinutes) {
                    Text(runtime).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                if regular, !episode.overview.isEmpty {
                    Text(episode.overview).font(.footnote).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            EpisodeActionButton(model: model, season: season, episode: episode.number, next: next)
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}
