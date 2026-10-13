import AMDBCore
import SwiftUI

/// IMDb rating plus Rotten Tomatoes critics (🍅 fresh / 🤢 rotten) and audience (🍿) scores.
struct RatingsBadges: View {
    let ratings: Ratings

    var body: some View {
        HStack(spacing: 10) {
            if let imdb = ratings.imdb {
                HStack(spacing: 5) {
                    Text("IMDb")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 3))
                    Text(String(format: "%.1f", imdb))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("IMDb \(String(format: "%.1f", imdb))")
            }
            if let critics = ratings.tomatoes {
                HStack(spacing: 3) {
                    Text(critics >= 60 ? "🍅" : "🤢")
                    Text("\(critics)%")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rotten Tomatoes critics \(critics) percent")
            }
            if let audience = ratings.popcorn {
                HStack(spacing: 3) {
                    Text("🍿")
                    Text("\(audience)%")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rotten Tomatoes audience \(audience) percent")
            }
        }
    }
}
