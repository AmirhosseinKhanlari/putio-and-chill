import AMDBCore
import SwiftUI

/// Apple TV–style row: large circular portraits cropped from the top so faces fill the circle.
struct CastAndCrewRow: View {
    let cast: [CastMember]
    let crew: [CastMember]
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(Router.self) private var router

    var body: some View {
        let compact = sizeClass == .compact
        let diameter: CGFloat = compact ? 104 : 140
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast & Crew").font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            Shelf {
                LazyHStack(alignment: .top, spacing: compact ? 14 : 22) {
                    ForEach(Array((cast + crew).enumerated()), id: \.offset) { _, person in
                        if let id = person.id {
                            Button { router.openPerson(id) } label: { PersonCircle(person: person, diameter: diameter) }
                                .buttonStyle(.lift)
                        } else {
                            PersonCircle(person: person, diameter: diameter)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}

private struct PersonCircle: View {
    let person: CastMember
    let diameter: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if person.profilePath == nil {
                    Circle().fill(.white.opacity(0.08))
                    Text(initials).font(.system(size: diameter * 0.3, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                } else {
                    RemoteImage(path: person.profilePath, size: "h632", seed: person.name, alignment: .top, neutral: true)
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.08)))
            Text(person.name).font(.subheadline.weight(.medium)).lineLimit(1)
            if let role = person.character, !role.isEmpty {
                Text(role).font(.footnote).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .frame(width: diameter + 20)
        .accessibilityElement(children: .combine)
    }

    private var initials: String {
        person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}
