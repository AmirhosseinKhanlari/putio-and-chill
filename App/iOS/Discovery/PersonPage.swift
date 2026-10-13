import AMDBCore
import AMDBKit
import SwiftUI

/// Everything one actor or filmmaker worked on: Known For row, then the full filmography, newest first.
struct PersonPage: View {
    let personID: Int
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var person: PersonDetail?
    @State private var failed = false
    @State private var bioExpanded = false

    var body: some View {
        let regular = sizeClass != .compact
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                if let person {
                    HStack(alignment: .center, spacing: regular ? 28 : 18) {
                        RemoteImage(path: person.profilePath, size: "h632", seed: person.name, alignment: .top, neutral: true)
                            .frame(width: regular ? 170 : 116, height: regular ? 170 : 116)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.1)))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(person.name).font(.system(size: regular ? 46 : 30, weight: .ultraLight)).lineLimit(2)
                            Text(meta(person)).font(.footnote).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                    .padding(.top, regular ? 64 : 56)

                    if !person.biography.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(person.biography).font(.callout).foregroundStyle(.white.opacity(0.82))
                                .lineLimit(bioExpanded ? nil : 4)
                            Button(bioExpanded ? "Less" : "More") { withAnimation { bioExpanded.toggle() } }
                                .font(.footnote.weight(.semibold))
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.horizontal, Metrics.gutter(sizeClass))
                    }

                    if !person.knownFor.isEmpty {
                        CatalogRowView(row: CatalogRow(id: "known-\(person.id)", title: "Known For", items: person.knownFor))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Filmography").font(.title3.weight(.semibold))
                        let width = Metrics.poster(sizeClass)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 30), spacing: 12, alignment: .top)],
                                  alignment: .leading, spacing: 18) {
                            ForEach(person.credits) { item in
                                Button { router.open(item) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        PosterCard(item: item, width: width)
                                        Text(item.year.map(String.init) ?? "Upcoming").font(.caption2).foregroundStyle(.white.opacity(0.5))
                                    }
                                }
                                .buttonStyle(.lift)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                } else if failed {
                    Text("Couldn't load this person.").foregroundStyle(.secondary).padding(.top, 100).frame(maxWidth: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 140)
                }
            }
            .padding(.bottom, 120)
        }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
        .task {
            guard person == nil, let catalog = app.catalog else { return }
            do {
                let loaded = try await catalog.person(id: personID)
                person = loaded
                if let top = loaded.knownFor.first { ambient.focus(top) }
            } catch {
                failed = true
            }
        }
    }

    private func meta(_ person: PersonDetail) -> String {
        var parts: [String] = []
        if let department = person.department { parts.append(department) }
        if let birthday = person.birthday, let date = Self.input.date(from: birthday) {
            parts.append("Born \(date.formatted(date: .long, time: .omitted))")
        }
        if let place = person.placeOfBirth { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    private static let input: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
