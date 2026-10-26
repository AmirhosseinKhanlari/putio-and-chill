import AMDBCore
import AMDBKit
import SwiftUI

struct PosterCard: View {
    let item: CatalogItem
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(path: item.posterPath, size: "w342", seed: item.title)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottomLeading) {
                    if item.posterPath == nil {
                        Text(item.title).font(.caption.weight(.bold)).padding(8).shadow(radius: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
            Text(item.title).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).frame(width: width, alignment: .leading)
        }
        .hoverEffect(.lift)
    }
}

struct LibraryPoster: View {
    let entry: LibraryEntry
    let width: CGFloat
    var resumeSeconds: Int = 0
    /// How much is watched and how long is left, when the video's length is known.
    var watched: Double?
    var left: Int?
    /// Watched to the end (`Watched`): a ✓ and a full bar.
    var isWatched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(path: entry.match?.posterPath, size: "w342", seed: entry.displayTitle)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        if entry.match?.posterPath == nil {
                            Text(entry.displayTitle).font(.caption.weight(.bold)).lineLimit(3)
                        }
                        if resumeSeconds >= 30 {
                            Label(left.map(Format.left) ?? "Resume \(Format.clock(resumeSeconds))", systemImage: "play.fill")
                                .font(.caption2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                        } else if isWatched {
                            WatchedBadge()
                        }
                    }
                    .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
            if let watched, resumeSeconds >= 30 {
                WatchedBar(fraction: watched, height: 3).frame(width: width)
            } else if isWatched {
                WatchedBar(fraction: 1, height: 3).frame(width: width)
            }
            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).frame(width: width, alignment: .leading)
        }
        .hoverEffect(.lift)
    }

    private var subtitle: String {
        if let match = entry.match, match.mediaType == .tv, let season = match.season {
            return "\(match.title) · S\(season)\(match.episode.map { " E\($0)" } ?? "")"
        }
        return entry.displayTitle
    }
}

/// "✓ Watched" on a poster or an episode's picture.
struct WatchedBadge: View {
    var body: some View {
        Label("Watched", systemImage: "checkmark")
            .font(.caption2.weight(.bold)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
    }
}
