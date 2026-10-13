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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter: LibraryFilter = .all

    var body: some View {
        let cards = LibraryCard.cards(from: app.library.entries, filter: filter)
        let width = Metrics.poster(sizeClass)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Text("Library").font(.system(size: sizeClass == .compact ? 34 : 48, weight: .ultraLight)).tracking(3)
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

    var body: some View {
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
