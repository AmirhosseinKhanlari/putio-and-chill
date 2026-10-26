import AMDBCore
import SwiftUI

/// Badge geometry: the same badges drawn about twice as big on Apple TV, read from across the room.
/// Text sizes follow the platform's own caption fonts; this scales the tags, dots and squares around them.
private enum Badge {
    #if os(tvOS)
    static let scale: CGFloat = 2
    static let spacing: CGFloat = 30
    #else
    static let scale: CGFloat = 1
    static let spacing: CGFloat = 10
    #endif
}

/// IMDb's yellow tag followed by the score.
struct IMDbScore: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 5 * Badge.scale) {
            Text("IMDb")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 4 * Badge.scale).padding(.vertical, Badge.scale)
                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 3 * Badge.scale))
            Text(String(format: "%.1f", rating))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("IMDb \(String(format: "%.1f", rating))")
    }
}

/// Every score we have for a title: IMDb, Rotten Tomatoes critics (🍅 fresh / 🤢 rotten) and audience (🍿),
/// Metacritic, Letterboxd, Trakt, and TMDB's user score. Wraps onto more lines when space runs out.
struct RatingsBadges: View {
    var ratings: Ratings?
    /// TMDB vote average (0–10), from the catalog — shown even without MDBList.
    var tmdb: Double?

    var body: some View {
        FlowLayout(spacing: Badge.spacing) {
            if let imdb = ratings?.imdb { IMDbScore(rating: imdb) }
            if let critics = ratings?.tomatoes {
                HStack(spacing: 3 * Badge.scale) {
                    Text(critics >= 60 ? "🍅" : "🤢")
                    Text("\(critics)%")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rotten Tomatoes critics \(critics) percent")
            }
            if let audience = ratings?.popcorn {
                HStack(spacing: 3 * Badge.scale) {
                    Text("🍿")
                    Text("\(audience)%")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rotten Tomatoes audience \(audience) percent")
            }
            if let metascore = ratings?.metacritic { MetacriticScore(score: metascore) }
            if let stars = ratings?.letterboxd { LetterboxdScore(stars: stars) }
            if let trakt = ratings?.trakt { TraktScore(rating: trakt) }
            if let tmdb, tmdb > 0 { TMDBScore(rating: tmdb) }
        }
    }

    static func hasAny(_ ratings: Ratings?, tmdb: Double?) -> Bool {
        !(ratings?.isEmpty ?? true) || (tmdb ?? 0) > 0
    }
}

/// Metacritic's colored square: green 61+, yellow 40–60, red below.
struct MetacriticScore: View {
    let score: Int

    var body: some View {
        HStack(spacing: 5 * Badge.scale) {
            Text("\(score)")
                .font(.caption.weight(.heavy).monospacedDigit())
                .foregroundStyle(score >= 40 && score < 61 ? .black : .white)
                .frame(minWidth: 22 * Badge.scale, minHeight: 18 * Badge.scale)
                .background(color, in: RoundedRectangle(cornerRadius: 4 * Badge.scale))
            Text("Metacritic").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Metacritic \(score)")
    }

    private var color: Color {
        if score >= 61 { return Color(red: 0.40, green: 0.80, blue: 0.20) }
        if score >= 40 { return Color(red: 1.0, green: 0.80, blue: 0.20) }
        return Color(red: 1.0, green: 0.0, blue: 0.0)
    }
}

/// Letterboxd's three dots (orange, green, blue) and the average out of 5.
struct LetterboxdScore: View {
    let stars: Double

    var body: some View {
        HStack(spacing: 5 * Badge.scale) {
            HStack(spacing: -3 * Badge.scale) {
                Circle().fill(Color(red: 1.0, green: 0.50, blue: 0.0))
                Circle().fill(Color(red: 0.0, green: 0.88, blue: 0.33)).blendMode(.screen)
                Circle().fill(Color(red: 0.25, green: 0.74, blue: 0.96)).blendMode(.screen)
            }
            .frame(width: 26 * Badge.scale, height: 10 * Badge.scale)
            .compositingGroup()
            Text(String(format: "%.1f", stars))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Letterboxd \(String(format: "%.1f", stars)) out of 5")
    }
}

/// "Trakt 8.4" in plain text: Trakt has no well-known badge to borrow.
struct TraktScore: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 5 * Badge.scale) {
            Text("Trakt").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            Text(String(format: "%.1f", rating))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trakt \(String(format: "%.1f", rating))")
    }
}

/// TMDB's user score as a percentage, with its green-to-blue tag.
struct TMDBScore: View {
    let rating: Double

    var body: some View {
        let percent = Int((rating * 10).rounded())
        HStack(spacing: 5 * Badge.scale) {
            Text("TMDB")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Color(red: 0.05, green: 0.15, blue: 0.25))
                .padding(.horizontal, 4 * Badge.scale).padding(.vertical, Badge.scale)
                .background(LinearGradient(colors: [Color(red: 0.56, green: 0.81, blue: 0.63), Color(red: 0.0, green: 0.71, blue: 0.89)],
                                           startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 3 * Badge.scale))
            Text("\(percent)%")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TMDB user score \(percent) percent")
    }
}
