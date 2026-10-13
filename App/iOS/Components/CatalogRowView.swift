import AMDBCore
import AMDBKit
import SwiftUI

struct CatalogRowView: View {
    let row: CatalogRow
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { item in
                        Button { router.open(item) } label: { PosterCard(item: item, width: Metrics.poster(sizeClass)) }
                            .buttonStyle(.lift)
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}

struct EntryRowView: View {
    let title: String
    let entries: [LibraryEntry]
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in
                        let resume = app.library.resumeSeconds(for: entry)
                        Button { router.play(entry, resumeFrom: resume) } label: {
                            LibraryPoster(entry: entry, width: Metrics.poster(sizeClass), resumeSeconds: resume)
                        }
                        .buttonStyle(.lift)
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}
