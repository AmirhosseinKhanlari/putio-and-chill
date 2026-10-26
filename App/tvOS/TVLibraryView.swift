import AMDBCore
import AMDBKit
import SwiftUI

/// Your put.io: storage, update / organize / clean up, transfers in flight, then everything as posters.
struct TVLibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var filter: LibraryFilter = .all
    @State private var cleanable: [LibraryEntry] = []
    @State private var confirmClean = false
    @State private var doomed: [LibraryEntry] = []
    @State private var notice: String?

    var body: some View {
        let cards = LibraryCard.cards(from: app.library.entries, filter: filter)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 28) {
                    TVPageHeader(title: "Library", subtitle: statusLine)
                    actions
                    if let notice { Text(notice).font(.system(size: 22)).foregroundStyle(TVMetrics.secondaryText) }
                }
                .padding(.horizontal, TVMetrics.edge)
                .focusSection()

                // Only what's still on its way: finished ones are in the library below (and Continue Watching).
                if app.transfers.tracked.contains(where: { $0.playableFile == nil }) { transfers }

                VStack(alignment: .leading, spacing: 30) {
                    HStack(spacing: 16) {
                        chip("All", .all)
                        chip("Movies", .movies)
                        chip("TV Shows", .tv)
                        chip("Other", .other)
                    }
                    .focusSection()
                    if cards.isEmpty {
                        Text(app.library.isRefreshing ? "Reading your put.io…" : "Nothing here yet.").foregroundStyle(TVMetrics.secondaryText)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.poster.width), spacing: 40), count: 6),
                              alignment: .leading, spacing: 50) {
                        ForEach(cards) { card in cardView(card) }
                    }
                }
                .padding(.horizontal, TVMetrics.edge)
            }
            .padding(.vertical, 40)
        }
        .tvPageBackground()
        .task { await loadCare() }
        .onChange(of: app.library.entries) { _, _ in Task { await loadCare() } }
        // Free space is asked for again after every update, so it never shows an old number.
        .onChange(of: app.library.lastUpdated) { _, _ in Task { await app.storage.refresh() } }
        .confirmationDialog(cleanTitle, isPresented: $confirmClean, titleVisibility: .visible) {
            Button("Delete \(cleanable.count) from put.io", role: .destructive) { Task { await delete(cleanable) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cleanMessage)
        }
        .confirmationDialog(doomedTitle, isPresented: Binding(get: { !doomed.isEmpty }, set: { if !$0 { doomed = [] } }),
                            titleVisibility: .visible) {
            let entries = doomed
            Button("Delete from put.io", role: .destructive) { Task { await delete(entries) } }
            Button("Cancel", role: .cancel) { doomed = [] }
        } message: {
            Text(doomedMessage)
        }
    }

    // MARK: Header

    private var statusLine: String {
        var parts: [String] = []
        if app.library.isRefreshing {
            parts.append("Updating from put.io…")
        } else if let updated = app.library.lastUpdated {
            parts.append("Updated \(RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: .now))")
        }
        if let disk = app.storage.disk { parts.append("\(Format.bytes(disk.used)) of \(Format.bytes(disk.size)) used · \(Format.bytes(disk.avail)) free") }
        if app.storage.trashSize > 0 { parts.append("\(Format.bytes(app.storage.trashSize)) in Trash") }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 24) {
            Button {
                Task {
                    await app.refreshLibraryIfDue(force: true)
                    notice = app.library.lastError == nil ? nil : "Couldn't reach put.io. Try again in a moment."
                }
            } label: {
                if app.library.isRefreshing { Label("Updating…", systemImage: "arrow.triangle.2.circlepath") }
                else { Label("Update Now", systemImage: "arrow.triangle.2.circlepath") }
            }
            .tvPill()
            .disabled(app.library.isRefreshing)
            Button { router.open(.files(.root)) } label: { Label("Files", systemImage: "folder") }
                .tvPill()
            Button { router.open(.organize) } label: { Label("Organize", systemImage: "folder.badge.gearshape") }
                .tvPill()
                .disabled(app.library.entries.isEmpty)
            if !cleanable.isEmpty {
                Button { confirmClean = true } label: { Label("Clean Up \(cleanable.count)", systemImage: "trash") }
                    .tvPill()
            }
        }
    }

    private var cleanMessage: String {
        let bytes: Int64 = cleanable.reduce(0) { $0 + ($1.file.size ?? 0) }
        return "Movies you watched to the end in Putio & Chill. Frees \(Format.bytes(bytes)). Shows and unwatched files are never touched."
    }
    private var doomedMessage: String {
        let bytes: Int64 = doomed.reduce(0) { $0 + ($1.file.size ?? 0) }
        return "This permanently deletes \(doomed.count == 1 ? "the file" : "\(doomed.count) files") from your put.io (\(Format.bytes(bytes)))."
    }
    private var cleanTitle: String { "Delete \(cleanable.count) finished movie\(cleanable.count == 1 ? "" : "s")?" }
    private var doomedTitle: String {
        doomed.count == 1 ? "Delete \u{201C}\(doomed[0].displayTitle)\u{201D}?" : "Delete \(doomed.count) episodes?"
    }

    // MARK: Transfers

    private var transfers: some View {
        TVShelf(title: "Downloading to put.io") {
            ForEach(app.transfers.tracked.filter { $0.playableFile == nil }) { transfer in
                let ready = transfer.playableFile != nil
                let failed = if case .failed = transfer.phase { true } else { false }
                TVWideCard(title: transfer.pending.title, subtitle: subtitle(transfer, ready: ready, failed: failed),
                           imagePath: transfer.pending.backdropPath ?? transfer.pending.posterPath,
                           progress: ready || failed ? nil : Double(transfer.percent) / 100) {
                    if ready {
                        router.playTransfer(transfer)
                    } else {
                        router.open(CatalogItem(tmdbID: transfer.pending.tmdbID, mediaType: transfer.pending.kind,
                                                title: transfer.pending.title, posterPath: transfer.pending.posterPath,
                                                backdropPath: transfer.pending.backdropPath))
                    }
                }
                .contextMenu {
                    if ready || failed {
                        Button("Dismiss") { app.transfers.dismiss(transfer.id) }
                    } else {
                        Button("Cancel Download", role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } }
                    }
                }
            }
        }
    }

    private func subtitle(_ transfer: TrackedTransfer, ready: Bool, failed: Bool) -> String {
        let episode = transfer.pending.season.map { "S\($0)" + (transfer.pending.episode.map { " E\($0)" } ?? "") + " · " } ?? ""
        if ready { return episode + "Ready to watch" }
        if failed { return episode + "Failed. Hold for options" }
        if transfer.isStalled { return episode + "Stalled: no peers" }
        return episode + ["\(transfer.percent)%", Format.speed(transfer.transfer?.downSpeed)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Grid

    private func chip(_ title: String, _ value: LibraryFilter) -> some View {
        Button(title) { filter = value }.tvChip(selected: filter == value)
    }

    @ViewBuilder private func cardView(_ card: LibraryCard) -> some View {
        switch card {
        case let .movie(entry):
            if let match = entry.match {
                let resume = app.library.resumeSeconds(for: entry)
                let badge = resume >= 30 ? app.library.remainingSeconds(for: entry).map(Format.left) ?? "Resume \(Format.clock(resume))"
                    : app.library.isWatched(entry) ? "✓ Watched" : nil
                TVPosterButton(item: TVEntryShelf.item(match), badge: badge) {
                    router.open(TVEntryShelf.item(match))
                }
                .contextMenu {
                    Button("Play") { router.play(entry, from: resume) }
                    Button("Fix Match…") { router.open(.fixMatch(.entries([entry]))) }
                    Button("Delete from put.io", role: .destructive) { doomed = [entry] }
                }
            }
        case let .show(tmdbID, title, posterPath, episodes):
            let item = CatalogItem(tmdbID: tmdbID, mediaType: .tv, title: title, posterPath: posterPath)
            // Every episode in put.io watched: ✓.
            let watched = !episodes.isEmpty && episodes.allSatisfy(app.library.isWatched)
            TVPosterButton(item: item, badge: "\(episodes.count) ep" + (watched ? " · ✓" : "")) { router.open(item) }
                .contextMenu {
                    Button("Fix Match…") { router.open(.fixMatch(.entries(episodes))) }
                    Button(episodes.count == 1 ? "Delete Episode" : "Delete All \(episodes.count) Episodes", role: .destructive) {
                        doomed = episodes
                    }
                }
        case let .file(entry):
            Button { router.play(entry, from: app.library.resumeSeconds(for: entry)) } label: {
                VStack(spacing: 14) {
                    Image(systemName: "film").font(.system(size: 44, weight: .light))
                    Text(entry.displayTitle).font(.system(size: 20, weight: .medium)).multilineTextAlignment(.center)
                        .lineLimit(4).padding(.horizontal, 16)
                }
                .frame(width: TVMetrics.poster.width, height: TVMetrics.poster.height)
                .background(Color(white: 0.1))
            }
            .buttonStyle(.card)
            .contextMenu {
                Button("Fix Match…") { router.open(.fixMatch(.entries([entry]))) }
                Button("Delete from put.io", role: .destructive) { doomed = [entry] }
            }
        }
    }

    // MARK: Work

    private func loadCare() async {
        await app.storage.refresh()
        // Clean Up offers every movie finished in Putio & Chill, or only older ones when auto-clean has a window set.
        cleanable = AutoCleaner.candidates(entries: app.library.entries, finished: await app.store.snapshot.finished,
                                           olderThanDays: app.settings.autoCleanDays ?? 0, now: Date())
    }

    private func delete(_ entries: [LibraryEntry]) async {
        doomed = []
        do {
            try await app.library.delete(entries)
            notice = "Deleted \(entries.count) item\(entries.count == 1 ? "" : "s") from put.io."
        } catch {
            notice = "Couldn't delete from put.io. Nothing was removed."
        }
        await loadCare()
    }
}

/// "Organize library" on the TV: what moves where, then Move.
struct TVOrganizeView: View {
    @Environment(AppModel.self) private var app
    @State private var plan: OrganizePlan?
    @State private var error: String?
    @State private var moving = false
    @State private var moved: Int?

    var body: some View {
        let layout = FolderLayout(settings: app.settings)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                TVPageHeader(title: "Organize Library",
                             subtitle: "Movies go to \(layout.displayPath(kind: .movie, title: "", season: nil)), shows to \(layout.displayPath(kind: .tv, title: "Show", season: app.settings.seasonFolders ? 1 : nil)).")
                if let moved {
                    Label("Moved \(moved) item\(moved == 1 ? "" : "s"). Your library is up to date.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                } else if let plan {
                    HStack(spacing: 30) {
                        Text(summary(plan)).font(.system(size: 26)).foregroundStyle(TVMetrics.secondaryText)
                        if !plan.isEmpty {
                            Button { Task { await apply(plan, layout: layout) } } label: {
                                Label(moving ? "Moving…" : "Move \(plan.moves.count)", systemImage: "arrow.right.circle.fill")
                            }
                            .tvPill()
                            .disabled(moving)
                        }
                    }
                    let groups = Dictionary(grouping: plan.moves, by: \.destination)
                    ForEach(groups.keys.sorted(), id: \.self) { destination in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(destination).font(.system(size: 26, weight: .semibold))
                            ForEach(groups[destination] ?? []) { move in
                                Button {} label: {
                                    Label(move.name, systemImage: move.isFolder ? "folder" : "film").font(.system(size: 22)).lineLimit(1)
                                }
                                .tvRow()
                            }
                        }
                    }
                    if !plan.unrecognized.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Left where they are").font(.system(size: 26, weight: .semibold))
                            Text("Putio & Chill isn't sure what these are, so it doesn't move them.").foregroundStyle(TVMetrics.secondaryText)
                            ForEach(plan.unrecognized) { entry in
                                Button {} label: { Text(entry.file.name).font(.system(size: 22)).lineLimit(1) }.tvRow()
                            }
                        }
                    }
                } else if let error {
                    Text(error)
                } else {
                    HStack(spacing: 20) { ProgressView(); Text("Looking through your library…").foregroundStyle(TVMetrics.secondaryText) }
                }
            }
            .padding(TVMetrics.edge)
            .frame(maxWidth: 1500, alignment: .leading)
        }
        .tvPageBackground()
        .task {
            guard plan == nil else { return }
            do { plan = try await app.planOrganize(layout: layout) } catch { self.error = "Couldn't read your put.io folders. Try again." }
        }
    }

    private func summary(_ plan: OrganizePlan) -> String {
        var parts = [plan.isEmpty ? "Everything is already in the right folder." : "\(plan.moves.count) item\(plan.moves.count == 1 ? "" : "s") will move."]
        if plan.inPlace > 0 { parts.append("\(plan.inPlace) already in place.") }
        if !plan.unrecognized.isEmpty { parts.append("\(plan.unrecognized.count) not recognized.") }
        return parts.joined(separator: " ")
    }

    private func apply(_ plan: OrganizePlan, layout: FolderLayout) async {
        moving = true
        defer { moving = false }
        do {
            moved = try await app.applyOrganize(plan, layout: layout)
        } catch {
            self.error = "Some items couldn't be moved. Nothing was deleted; try again."
            self.plan = nil
        }
    }
}
