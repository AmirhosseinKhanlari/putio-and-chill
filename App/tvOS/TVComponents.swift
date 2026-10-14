import AMDBCore
import AMDBKit
import SwiftUI

// Design A ("Apple TV"): black, full-bleed art, quiet gray metadata, ratings as plain text,
// glass buttons that turn white with black text when focused.

enum TVMetrics {
    static let poster = CGSize(width: 250, height: 375)
    static let wide = CGSize(width: 420, height: 236)
    static let edge: CGFloat = 24
    static let secondaryText = Color.white.opacity(0.68)
}

// MARK: Buttons

/// Capsule button: frosted glass at rest, solid white with black text when focused (like Apple's TV app).
struct TVPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVPillBody(configuration: configuration, circle: false)
    }
}

/// Round icon button (＋, ⋯, trailer) with the same focus treatment.
struct TVCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVPillBody(configuration: configuration, circle: true)
    }
}

private struct TVPillBody: View {
    let configuration: ButtonStyle.Configuration
    let circle: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .font(.system(size: 27, weight: .semibold))
            .labelStyle(TVActionLabelStyle())
            .foregroundStyle(focused ? Color.black : .white)
            .padding(.horizontal, circle ? 0 : 38)
            .frame(width: circle ? 76 : nil, height: 76)
            .background {
                if focused {
                    Capsule().fill(.white)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (focused ? 1.08 : 1))
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 24, y: 14)
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}

extension View {
    func tvPill() -> some View { buttonStyle(TVPillStyle()) }
    func tvCircle() -> some View { buttonStyle(TVCircleStyle()) }
    func tvChip(selected: Bool) -> some View { buttonStyle(TVChipStyle(selected: selected)) }
    func tvRow() -> some View { buttonStyle(TVRowStyle()) }
}

/// Filter / mood / season chip: the chosen one reads brighter; focus is white like every other button.
struct TVChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVChipBody(configuration: configuration, selected: selected)
    }

    private struct TVChipBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.system(size: 24, weight: selected ? .bold : .medium))
                .foregroundStyle(focused ? Color.black : .white.opacity(selected ? 1 : 0.7))
                .padding(.horizontal, 30).frame(height: 60)
                .background {
                    if focused {
                        Capsule().fill(.white)
                    } else {
                        Capsule().fill(.white.opacity(selected ? 0.24 : 0.07))
                    }
                }
                .scaleEffect(focused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

/// Full-width list row (charts, organize preview, settings-like lists).
struct TVRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVRowBody(configuration: configuration)
    }

    private struct TVRowBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.black : .white)
                .padding(.horizontal, 26).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(focused ? .white : .white.opacity(0.05)))
                .scaleEffect(focused ? 1.02 : 1)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

/// Big page title with an optional gray line underneath.
struct TVPageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 64, weight: .bold))
            if let subtitle { Text(subtitle).font(.system(size: 24, weight: .medium)).foregroundStyle(TVMetrics.secondaryText) }
        }
    }
}

/// Icon + title at one size so rows of buttons line up.
struct TVActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.frame(width: 28, height: 28)
            configuration.title
        }
    }
}

// MARK: Text lines

/// "Movie · Science Fiction · 2024 · 2 hr 47 min" in quiet gray.
struct TVMetaLine: View {
    let item: CatalogItem
    var detail: TitleDetail?
    var extra: [String] = []

    var body: some View {
        let kind = item.mediaType == .tv ? "Series" : "Movie"
        let genre = detail?.genres.first
        let year = item.year.map(String.init)
        let runtime = detail?.runtimeMinutes.flatMap { minutes in
            minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
        }
        Text(([kind, genre, year, runtime] + extra.map(Optional.some)).compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(TVMetrics.secondaryText)
    }
}

/// "IMDb 8.5   Rotten Tomatoes 92%   Metacritic 79   Letterboxd 4.4   TMDB 74%" — plain text, no boxes.
struct TVRatingsLine: View {
    var ratings: Ratings?
    var tmdb: Double?

    var body: some View {
        let parts = Self.parts(ratings, tmdb: tmdb)
        if !parts.isEmpty {
            HStack(spacing: 30) {
                ForEach(parts, id: \.0) { part in
                    (Text(part.0 + " ").fontWeight(.semibold).foregroundStyle(.white.opacity(0.92))
                     + Text(part.1).fontWeight(.medium).foregroundStyle(TVMetrics.secondaryText))
                }
            }
            .font(.system(size: 23))
            .accessibilityElement(children: .combine)
        }
    }

    static func parts(_ ratings: Ratings?, tmdb: Double?) -> [(String, String)] {
        var parts: [(String, String)] = []
        if let imdb = ratings?.imdb { parts.append(("IMDb", String(format: "%.1f", imdb))) }
        if let tomatoes = ratings?.tomatoes { parts.append(("Rotten Tomatoes", "\(tomatoes)%")) }
        if let popcorn = ratings?.popcorn { parts.append(("Audience", "\(popcorn)%")) }
        if let metacritic = ratings?.metacritic { parts.append(("Metacritic", "\(metacritic)")) }
        if let letterboxd = ratings?.letterboxd { parts.append(("Letterboxd", String(format: "%.1f", letterboxd))) }
        if ratings?.imdb == nil, let tmdb, tmdb > 0 { parts.append(("TMDB", "\(Int((tmdb * 10).rounded()))%")) }
        return parts
    }
}

/// Logo when TMDB has one, else the title in bold display type.
struct TVTitleArt: View {
    let item: CatalogItem
    var logoPath: String?
    var maxWidth: CGFloat = 560

    var body: some View {
        if let logoPath {
            RemoteImage(path: logoPath, size: "w500", seed: item.title, contentMode: .fit, alignment: .leading)
                .frame(maxWidth: maxWidth, maxHeight: 150, alignment: .leading)
                .accessibilityLabel(item.title)
        } else {
            Text(item.title)
                .font(.system(size: 76, weight: .bold))
                .lineLimit(2).minimumScaleFactor(0.6)
                .frame(maxWidth: 1100, alignment: .leading)
        }
    }
}

/// Full-screen art with the A-style darkening (left and bottom), fixed behind a page.
struct TVBackdrop: View {
    let path: String?
    let seed: String

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(path: path, size: "original", seed: seed)
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.2),
                                   .init(color: .clear, location: 0.45), .init(color: .black.opacity(0.85), location: 0.78),
                                   .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

// MARK: Cards and rows

/// Poster that lifts when focused (tvOS card style).
struct TVPosterButton: View {
    let item: CatalogItem
    var size = TVMetrics.poster
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RemoteImage(path: item.posterPath ?? item.backdropPath, size: "w342", seed: item.title)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .bottomLeading) {
                    if item.posterPath == nil {
                        Text(item.title).font(.system(size: 24, weight: .semibold)).padding(16).lineLimit(3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge).font(.system(size: 18, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule()).padding(10)
                    }
                }
        }
        .buttonStyle(.card)
        .accessibilityLabel(item.title)
    }
}

/// Wide 16:9 card with the title underneath and an optional progress bar on the image.
struct TVWideCard: View {
    let title: String
    let subtitle: String?
    let imagePath: String?
    var progress: Double?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                RemoteImage(path: imagePath, size: "w780", seed: title)
                    .frame(width: TVMetrics.wide.width, height: TVMetrics.wide.height)
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0 {
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(.white).frame(width: (TVMetrics.wide.width - 40) * min(progress, 1))
                            }
                            .frame(height: 6)
                            .padding(.horizontal, 20).padding(.bottom, 16)
                        }
                    }
            }
            .buttonStyle(.card)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 23, weight: .semibold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 20)).foregroundStyle(TVMetrics.secondaryText).lineLimit(1) }
            }
            .frame(width: TVMetrics.wide.width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A titled horizontal row.
struct TVShelf<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 30, weight: .semibold))
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, TVMetrics.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) { content() }
                    .padding(.horizontal, TVMetrics.edge)
                    .padding(.vertical, 34)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// Catalog row of posters.
struct TVCatalogShelf: View {
    let row: CatalogRow
    @Environment(TVRouter.self) private var router

    var body: some View {
        TVShelf(title: row.title) {
            ForEach(row.items) { item in TVPosterButton(item: item) { router.open(item) } }
        }
    }
}

/// Library entries (Continue Watching, Recently Added) as wide cards that play straight away.
struct TVEntryShelf: View {
    let title: String
    let entries: [LibraryEntry]
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    var body: some View {
        TVShelf(title: title) {
            ForEach(entries) { entry in
                let resume = app.library.resumeSeconds(for: entry)
                TVWideCard(title: entry.match?.title ?? entry.displayTitle, subtitle: Self.caption(entry, resume: resume),
                           imagePath: entry.match?.backdropPath ?? entry.match?.posterPath) {
                    router.play(entry, from: resume)
                }
            }
        }
    }

    static func caption(_ entry: LibraryEntry, resume: Int) -> String? {
        let episode = entry.match.flatMap { match in match.season.map { "S\($0)" + (match.episode.map { " E\($0)" } ?? "") } }
        let time = resume >= 30 ? "Resume \(Format.clock(resume))" : nil
        let parts = [episode, time].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func item(_ match: LibraryMatch) -> CatalogItem {
        CatalogItem(tmdbID: match.tmdbID, mediaType: match.mediaType, title: match.title, posterPath: match.posterPath,
                    backdropPath: match.backdropPath, year: match.year)
    }
}

/// Round cast photo with name and role; opens the person.
struct TVCastCircle: View {
    let member: CastMember
    var role: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Button(action: action) {
                ZStack {
                    Color.white.opacity(0.1)
                    if member.profilePath != nil {
                        RemoteImage(path: member.profilePath, size: "w185", seed: member.name, alignment: .top)
                    } else {
                        Text(member.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                            .font(.system(size: 52, weight: .light))
                    }
                }
                .frame(width: 180, height: 180)
                .clipShape(Circle())
            }
            .buttonStyle(.card)
            .clipShape(Circle())
            VStack(spacing: 4) {
                Text(member.name).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
                if let role = role ?? member.character, !role.isEmpty {
                    Text(role).font(.system(size: 19)).foregroundStyle(TVMetrics.secondaryText).lineLimit(1)
                }
            }
            .frame(width: 200)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Black page background used by every non-art screen.
extension View {
    func tvPageBackground() -> some View { background(Color.black.ignoresSafeArea()) }
}
