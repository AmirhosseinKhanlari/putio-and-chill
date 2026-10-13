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
        List {
            Section {
                Text(request.target.title + label).font(.title3.weight(.semibold))
                if let message { Text(message).foregroundStyle(Theme.poor) }
            }
            if !request.playNow.isEmpty {
                Section("Already in put.io") {
                    ForEach(request.playNow) { entry in
                        Button { router.play(entry, from: app.library.resumeSeconds(for: entry)) } label: {
                            Label(entry.file.name, systemImage: "play.fill").lineLimit(1)
                        }
                    }
                }
            }
            if let model {
                Section {
                    if model.rows.isEmpty {
                        HStack(spacing: 16) {
                            if model.isLoading { ProgressView() }
                            Text(model.isLoading ? "Searching sources…" : "No versions found.").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.rows) { release in
                        Button { Task { await send(release) } } label: { row(release, inPutio: model.isInPutio(release)) }
                            .disabled(sending != nil)
                    }
                } header: {
                    Text(model.isLoading && !model.rows.isEmpty ? "Versions · still searching…" : "Versions")
                }
            }
        }
        .frame(maxWidth: 1500)
        .frame(maxWidth: .infinity)
        .ambientBackground()
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

    private var label: String {
        switch (request.target.season, request.target.episode) {
        case let (season?, episode?): " · S\(season) E\(episode)"
        case let (season?, nil): " · Season \(season)"
        default: ""
        }
    }

    private func row(_ release: Release, inPutio: Bool) -> some View {
        HStack(spacing: 24) {
            Text(release.parsed.resolution.label)
                .font(.callout.weight(.bold)).frame(width: 110)
                .padding(.vertical, 6).background(.white.opacity(0.12), in: Capsule())
            VStack(alignment: .leading, spacing: 6) {
                Text(release.name).font(.callout).lineLimit(1)
                Text([Format.bytes(release.sizeBytes), release.seeders.map { "\($0) seeders" },
                      release.sources.sorted().first?.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if inPutio { Label("In put.io", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.caption) }
            if sending == release.id { ProgressView() }
        }
    }

    private func send(_ release: Release) async {
        sending = release.id
        defer { sending = nil }
        do {
            try await app.transfers.send(release, target: request.target)
            dismiss()
        } catch {
            message = "Couldn't send that to put.io. Try another version."
        }
    }
}
