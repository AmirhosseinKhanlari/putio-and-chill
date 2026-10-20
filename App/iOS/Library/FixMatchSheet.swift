import AMDBCore
import AMDBKit
import SwiftUI

/// Fix Match: pick the movie or show some files really are (search TMDB), for a show optionally the season they
/// are, and what it applies to. Opened from a Library card or a Files row.
struct FixMatchSheet: View {
    let request: FixMatchRequest
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: FixMatchModel?
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let model {
                    content(model).padding(Metrics.gutter(sizeClass) / 2 + 8)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            }
            .background(Theme.sheet)
            .navigationTitle("Fix Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.sheet)
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let fix = request.model(catalog: catalog, library: app.library)
            model = fix
            fix.search()
        }
    }

    @ViewBuilder private func content(_ model: FixMatchModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text(request.sampleName).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            if let chosen = model.chosen {
                chosenSection(model, chosen)
            } else {
                HStack(spacing: 8) {
                    TextField("Movie or show title", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { model.search() }
                        .accessibilityIdentifier("fixmatch.search")
                    Button("Search") { model.search() }.buttonStyle(.glassPill)
                }
                if model.isSearching {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if model.searchFailed {
                    Text("Couldn't reach TMDB. Check your connection and search again.").font(.footnote).foregroundStyle(Theme.poor)
                } else if model.results.isEmpty {
                    Text("Nothing found. Try another spelling, or fewer words.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.results) { item in
                    Button { Task { await model.choose(item) } } label: { ResultRow(item: item) }
                        .buttonStyle(.plain)
                }
            }
            if model.canUndo {
                Divider().padding(.vertical, 4)
                Button {
                    Task {
                        working = true
                        router.toast = await model.undo(files: request.files, folderID: request.folderID)
                        dismiss()
                    }
                } label: { Label("Match Automatically", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.glassPill)
                .disabled(working)
                Text("Forgets the title picked for these files and looks them up again.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func chosenSection(_ model: FixMatchModel, _ chosen: CatalogItem) -> some View {
        @Bindable var model = model
        ResultRow(item: chosen, selected: true)
        Button("Pick another title") { model.clearChoice() }.font(.footnote.weight(.semibold))
        if chosen.mediaType == .tv {
            Text("Season").font(.headline).padding(.top, 6)
            Picker("Season", selection: $model.season) {
                Text(model.namedSeason.map { "As named (season \($0))" } ?? "As named").tag(Int?.none)
                ForEach(model.seasons, id: \.number) { season in
                    Text(season.name == "Season \(season.number)" ? season.name : "Season \(season.number) · \(season.name)")
                        .tag(Int?.some(season.number))
                }
            }
            .pickerStyle(.menu)
            Text("Use this when the files count seasons differently, e.g. \u{201C}S03\u{201D} files that are this show\u{2019}s season 1.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.targets.count > 1 {
            Text("Apply to").font(.headline).padding(.top, 6)
            VStack(spacing: 6) {
                ForEach(model.targets, id: \.self) { target in
                    Button { model.target = target } label: {
                        HStack {
                            Text(target.label).font(.subheadline).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: model.target == target ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.target == target ? Theme.good : .secondary)
                        }
                        .padding(12)
                        .background(.white.opacity(model.target == target ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.target == target ? .isSelected : [])
                }
            }
        } else {
            Text(model.target.label).font(.footnote).foregroundStyle(.secondary)
        }
        Button { Task { await apply(model) } } label: {
            Label("Apply", systemImage: "checkmark").frame(maxWidth: .infinity)
        }
        .buttonStyle(.primaryPill)
        .disabled(working)
        .padding(.top, 8)
        .accessibilityIdentifier("fixmatch.apply")
    }

    private func apply(_ model: FixMatchModel) async {
        working = true
        defer { working = false }
        if let done = await model.apply() { router.toast = done }
        dismiss()
    }
}

/// One TMDB result: poster, title, year and whether it's a movie or a show.
private struct ResultRow: View {
    let item: CatalogItem
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: item.posterPath, size: "w185", seed: item.title)
                .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Text([item.mediaType == .tv ? "Show" : "Movie", item.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good) }
        }
        .padding(10)
        .background(.white.opacity(selected ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}
