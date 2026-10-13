import AMDBCore
import AMDBKit
import SwiftUI

struct BrowseView: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: BrowseModel?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                Text(kind == .tv ? "TV Shows" : "Movies")
                    .font(.system(size: sizeClass == .compact ? 34 : 48, weight: .ultraLight)).tracking(3)
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                    .padding(.top, 12)
                if model?.isLoading == true && model?.rows.isEmpty == true {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(model?.rows ?? []) { CatalogRowView(row: $0) }
            }
            .padding(.bottom, 120)
        }
        .ignoresSafeArea(.keyboard)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let browse = BrowseModel(kind: kind, catalog: catalog)
            model = browse
            await browse.load()
            if let first = browse.rows.first?.items.first { ambient.focus(first) }
        }
    }
}
