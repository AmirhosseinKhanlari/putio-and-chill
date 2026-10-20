import AMDBCore
import AMDBKit
import SwiftUI

/// Fix Match on the TV (hold Select on a Library card or a Files row): search TMDB for the right title, for a show
/// optionally the season the files are, choose what it applies to, Apply. Or Match Automatically to undo.
struct TVFixMatchView: View {
    let request: FixMatchRequest
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var model: FixMatchModel?
    @State private var working = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                TVPageHeader(title: "Fix Match", subtitle: request.sampleName)
                if let model { content(model) } else { ProgressView() }
            }
            .padding(TVMetrics.edge)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .tvPageBackground()
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let fix = request.model(catalog: catalog, library: app.library)
            model = fix
            fix.search()
        }
    }

    @ViewBuilder private func content(_ model: FixMatchModel) -> some View {
        @Bindable var model = model
        if let chosen = model.chosen {
            chosenSection(model, chosen)
        } else {
            HStack(spacing: 24) {
                TextField("Movie or show title", text: $model.query)
                    .frame(width: 900)
                    .onSubmit { model.search() }
                Button { model.search() } label: { Label("Search", systemImage: "magnifyingglass") }.tvPill()
            }
            if model.isSearching {
                ProgressView().padding(.top, 20)
            } else if model.searchFailed {
                Text("Couldn't reach TMDB. Check your connection and search again.").font(.system(size: 24)).foregroundStyle(Theme.okay)
            } else if model.results.isEmpty {
                Text("Nothing found. Try another spelling, or fewer words.").font(.system(size: 24)).foregroundStyle(TVMetrics.secondaryText)
            }
            ForEach(model.results) { item in
                Button { Task { await model.choose(item) } } label: { resultRow(item) }.tvRow()
            }
        }
        if model.canUndo {
            Button {
                Task {
                    working = true
                    router.notice = await model.undo(files: request.files, folderID: request.folderID)
                    router.goBack()
                }
            } label: { Label("Match Automatically", systemImage: "arrow.uturn.backward") }
            .tvPill()
            .disabled(working)
            .padding(.top, 20)
        }
    }

    @ViewBuilder private func chosenSection(_ model: FixMatchModel, _ chosen: CatalogItem) -> some View {
        resultRow(chosen)
        Button("Pick Another Title") { model.clearChoice() }.tvPill()
        if chosen.mediaType == .tv {
            sectionTitle("Season")
            Text("Pick one when the files count seasons differently, e.g. \u{201C}S03\u{201D} files that are this show\u{2019}s season 1.")
                .font(.system(size: 22)).foregroundStyle(TVMetrics.secondaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    Button(model.namedSeason.map { "As Named (Season \($0))" } ?? "As Named") { model.season = nil }
                        .tvChip(selected: model.season == nil)
                    ForEach(model.seasons, id: \.number) { season in
                        Button(season.name == "Season \(season.number)" ? season.name : "Season \(season.number) · \(season.name)") {
                            model.season = season.number
                        }
                        .tvChip(selected: model.season == season.number)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
        sectionTitle("Apply To")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.targets, id: \.self) { target in
                Button(target.label) { model.target = target }.tvChip(selected: model.target == target)
            }
        }
        Button {
            Task {
                working = true
                if let done = await model.apply() { router.notice = done }
                router.goBack()
            }
        } label: { Label("Apply", systemImage: "checkmark") }
        .tvPill()
        .disabled(working)
        .padding(.top, 20)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 28, weight: .semibold)).padding(.top, 16)
    }

    private func resultRow(_ item: CatalogItem) -> some View {
        HStack(spacing: 24) {
            RemoteImage(path: item.posterPath, size: "w185", seed: item.title)
                .frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                Text([item.mediaType == .tv ? "Show" : "Movie", item.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 20)).opacity(0.7)
            }
            Spacer(minLength: 0)
        }
    }
}
