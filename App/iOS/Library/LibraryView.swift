import AMDBCore
import AMDBKit
import SwiftUI

extension LibraryFilter {
    var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .tv: "TV"
        case .other: "Other"
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter: LibraryFilter = .all

    var body: some View {
        let cards = LibraryCard.cards(from: app.library.entries, filter: filter)
        let width = Metrics.poster(sizeClass)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library").font(.system(size: sizeClass == .compact ? 34 : 48, weight: .ultraLight)).tracking(3)
                    LibraryFreshness()
                }
                StorageMeter()
                if !app.downloads.records.isEmpty {
                    Text("On this device").font(.title3.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) { ForEach(app.downloads.records) { DownloadCard(record: $0) } }
                    }
                }
                if !app.myList.items.isEmpty {
                    HStack {
                        Text("My List").font(.title3.weight(.semibold))
                        Spacer()
                        Button("See all") { router.openMyList() }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .accessibilityLabel("See all My List")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(app.myList.items.map(\.catalogItem)) { item in
                                Button { router.open(item) } label: { PosterCard(item: item, width: width * 0.8) }
                                    .buttonStyle(.lift)
                            }
                        }
                    }
                }
                if !app.transfers.tracked.isEmpty {
                    Text("Transfers").font(.title3.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) { ForEach(app.transfers.tracked) { TransferCard(transfer: $0) } }
                    }
                }
                Picker("Filter", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                if cards.isEmpty {
                    if app.library.isRefreshing {
                        ProgressView("Reading your put.io…").frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        Text(app.library.lastError == nil ? "Nothing here yet." : "Couldn't read your put.io files. Pull to retry.")
                            .foregroundStyle(.secondary).padding(.top, 40)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 30), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(cards) { LibraryCardView(card: $0, width: width) }
                }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .refreshable { await app.library.refresh() }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct LibraryCardView: View {
    let card: LibraryCard
    let width: CGFloat
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(OfflineDownloader.self) private var downloader
    @State private var confirmDelete = false

    private var entries: [LibraryEntry] {
        switch card {
        case let .movie(entry), let .file(entry): [entry]
        case let .show(_, _, _, episodes): episodes
        }
    }

    var body: some View {
        content
            .contextMenu {
                if case let .movie(entry) = card, OfflineDownloader.isSupported {
                    if app.downloads.record(fileID: entry.id) == nil {
                        Button { Task { await downloader.start(entry) } } label: { Label("Download", systemImage: "arrow.down.to.line") }
                    } else {
                        Button { Task { await downloader.remove(fileID: entry.id) } } label: { Label("Remove download", systemImage: "minus.circle") }
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(entries.count > 1 ? "Delete \(entries.count) episodes from put.io" : "Delete from put.io", systemImage: "trash")
                }
            }
            .confirmationDialog("Delete from put.io?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { try? await app.library.delete(entries) } }
            } message: {
                Text("This removes \(entries.count == 1 ? "the file" : "\(entries.count) files") from your put.io account. It can't be undone in AMDB.")
            }
    }

    @ViewBuilder private var content: some View {
        switch card {
        case let .movie(entry), let .file(entry):
            let resume = app.library.resumeSeconds(for: entry)
            Button { router.play(entry, resumeFrom: resume) } label: {
                LibraryPoster(entry: entry, width: width, resumeSeconds: resume)
            }
            .buttonStyle(.lift)
        case let .show(tmdbID, title, posterPath, episodes):
            Button {
                router.open(CatalogItem(tmdbID: tmdbID, mediaType: .tv, title: title, posterPath: posterPath,
                                        backdropPath: episodes.first?.match?.backdropPath))
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    RemoteImage(path: posterPath, size: "w342", seed: title)
                        .frame(width: width, height: width * 1.5)
                        .overlay(alignment: .topTrailing) {
                            Text("\(episodes.count)").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule()).padding(6)
                        }
                        .overlay(alignment: .bottomLeading) {
                            if posterPath == nil { Text(title).font(.caption.weight(.bold)).padding(8) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(title).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).frame(width: width, alignment: .leading)
                }
                .hoverEffect(.lift)
            }
            .buttonStyle(.lift)
        }
    }
}

private struct TransferCard: View {
    let transfer: TrackedTransfer
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: transfer.pending.posterPath, size: "w185", seed: transfer.pending.title)
                .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(transfer.pending.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if transfer.playableFile != nil {
                    Button { router.play(transfer) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.primaryPill)
                } else {
                    DownloadStatus(transfer: transfer)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if transfer.notified {
                    Button("Dismiss") { app.transfers.dismiss(transfer.id) }
                } else {
                    Button("Cancel transfer", role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        }
        .padding(12)
        .frame(width: 320)
        .glassRounded(16)
    }
}

private struct DownloadCard: View {
    let record: DownloadRecord
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(OfflineDownloader.self) private var downloader

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: record.posterPath, size: "w185", seed: record.title)
                .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
            }
            Spacer(minLength: 0)
            Menu {
                Button(role: .destructive) { Task { await downloader.cancel(fileID: record.fileID) } } label: {
                    Label("Remove download", systemImage: "trash")
                }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        }
        .padding(12)
        .frame(width: 300)
        .glassRounded(16)
    }

    private var status: String {
        switch record.state {
        case .queued: "Waiting…"
        case let .downloading(progress): "Downloading \(Int(progress * 100))%"
        case .done: "Available offline"
        case let .failed(message): "Failed: \(message)"
        }
    }
}

/// "Updated 12 min ago" / "Updating from put.io…" under the Library title.
struct LibraryFreshness: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                if app.library.isRefreshing {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Updating from put.io…")
                } else if let updated = app.library.lastUpdated {
                    Image(systemName: "checkmark.icloud")
                    Text("Updated \(Self.relative(updated, now: context.date))")
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}
