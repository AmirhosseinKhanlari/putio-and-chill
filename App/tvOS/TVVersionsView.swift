import AMDBCore
import AMDBKit
import SwiftUI

/// Every release found for a movie, season or episode, best first; choosing one sends it to put.io.
struct TVVersionsView: View {
    let request: TVVersionsRequest
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model: VersionsModel?
    @State private var sending: String?
    @State private var message: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 14) {
                TVPageHeader(title: (request.target?.title ?? Self.queryText(request.query)) + label, subtitle: status)
                    .padding(.bottom, 20)
                if let message { Text(message).font(.system(size: 24, weight: .semibold)).padding(.bottom, 10) }
                if !request.playNow.isEmpty {
                    sectionTitle("Already in put.io")
                    ForEach(request.playNow) { entry in
                        Button { router.play(entry, from: app.library.resumeSeconds(for: entry)) } label: {
                            Label(entry.file.name, systemImage: "play.fill").font(.system(size: 24, weight: .medium)).lineLimit(1)
                        }
                        .tvRow()
                    }
                    sectionTitle("Versions").padding(.top, 20)
                }
                if let model {
                    if model.rows.isEmpty, !model.isLoading {
                        Text("No versions found.").foregroundStyle(TVMetrics.secondaryText)
                    }
                    if model.rows.isEmpty, model.isLoading { ProgressView().padding(.top, 30) }
                    ForEach(model.rows) { release in
                        Button { Task { await send(release) } } label: { row(release, inPutio: model.isInPutio(release)) }
                            .tvRow()
                            .disabled(sending != nil)
                    }
                }
            }
            .padding(TVMetrics.edge)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .tvPageBackground()
        .task {
            guard model == nil else { return }
            let hashes = await app.completedHashes()
            let versions = VersionsModel(query: request.query, searcher: app.releaseSearcher, playNow: request.playNow,
                                         completedHashes: hashes,
                                         defaultResolution: app.settings.defaultResolution.flatMap(Resolution.init(rawValue:)))
            model = versions
            versions.start()
        }
        .onDisappear { model?.cancel() }
    }

    static func queryText(_ query: MediaQuery) -> String {
        if case let .text(text) = query { return "\u{201C}\(text)\u{201D}" }
        return query.searchText
    }

    private var status: String {
        guard let model else { return "Searching sources…" }
        if model.isLoading { return model.rows.isEmpty ? "Searching sources…" : "\(model.rows.count) found · still searching…" }
        return "\(model.rows.count) version\(model.rows.count == 1 ? "" : "s") · best first"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 28, weight: .semibold)).padding(.bottom, 4)
    }

    private var label: String {
        switch (request.target?.season, request.target?.episode) {
        case let (season?, episode?): " · S\(season) E\(episode)"
        case let (season?, nil): " · Season \(season)"
        default: ""
        }
    }

    private func row(_ release: Release, inPutio: Bool) -> some View {
        HStack(spacing: 24) {
            Text(release.parsed.resolution.label)
                .font(.system(size: 22, weight: .bold)).frame(width: 100)
                .padding(.vertical, 6).overlay(Capsule().strokeBorder(lineWidth: 2).opacity(0.5))
            VStack(alignment: .leading, spacing: 6) {
                Text(release.name).font(.system(size: 23, weight: .medium)).lineLimit(1)
                Text([Format.bytes(release.sizeBytes), release.seeders.map { "\($0) seeders" },
                      release.sources.sorted().first?.name, inPutio ? "In put.io" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 20)).opacity(0.7)
            }
            Spacer()
            if sending == release.id { ProgressView() }
        }
    }

    private func send(_ release: Release) async {
        sending = release.id
        defer { sending = nil }
        do {
            let target = request.target ?? TransferTarget(
                tmdbID: 0, kind: release.parsed.season == nil ? .movie : .tv,
                title: release.parsed.title.isEmpty ? release.name : release.parsed.title,
                posterPath: nil, backdropPath: nil, season: release.parsed.season, episode: release.parsed.episode)
            try await app.transfers.send(release, target: target)
            dismiss()
        } catch {
            message = "Couldn't send that to put.io. Try another version."
        }
    }
}
