import AMDBCore
import AMDBKit
import SwiftUI

struct VersionsSheet: View {
    let request: VersionsRequest
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: VersionsModel?
    @State private var sendingID: String?
    @State private var errorText: String?
    /// A version that doesn't fit in put.io: what could be deleted to make room for it.
    @State private var roomOffer: RoomOffer?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !request.playNow.isEmpty {
                        Text("Already in your put.io").font(.headline)
                        ForEach(request.playNow) { entry in
                            Button {
                                dismiss()
                                router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry))
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.good)
                                    Text(entry.file.name).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer()
                                    Text("Play now").font(.caption.weight(.bold))
                                }
                                .padding(12)
                                .background(Theme.good.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.bottom, 8)
                    }
                    if let model {
                        FilterBar(model: model)
                        ForEach(model.failures, id: \.providerID) { failure in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.okay)
                                Text("\(failure.providerID) didn't answer").font(.caption)
                                Spacer()
                                Button("Retry") { model.start() }.font(.caption.weight(.bold))
                            }
                            .padding(10)
                            .background(Theme.okay.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        ForEach(model.rows) { release in
                            Button { send(release) } label: {
                                ReleaseRow(release: release, inPutio: model.isInPutio(release), sending: sendingID == release.id)
                            }
                            .buttonStyle(.plain)
                            .disabled(sendingID != nil)
                        }
                        if !model.isLoading, model.snapshot.hiddenCount > 0 {
                            Text(model.snapshot.hiddenCount == 1 ? "1 version that looks fake is hidden."
                                 : "\(model.snapshot.hiddenCount) versions that look fake are hidden.")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 4)
                        }
                        if model.isLoading {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(model.snapshot.isCheckingFiles ? "Checking files…" : "Searching \(model.snapshot.pendingProviders.count) sources…")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                        } else if model.rows.isEmpty {
                            VStack(spacing: 8) {
                                Text("No versions found").font(.headline)
                                Text(model.emptyHint)
                                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Search again") { model.start() }.buttonStyle(.glassPill)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
                .padding(Metrics.gutter(sizeClass) / 2 + 8)
            }
            .background(Theme.sheet)
            .navigationTitle("Choose a version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if let model {
                    ToolbarItem(placement: .primaryAction) { SortMenu(model: model) }
                }
            }
            .alert("Couldn't send to put.io", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .sheet(item: $roomOffer) { offer in
                MakeRoomSheet(offer: offer) { message in
                    guard let message else { return }
                    router.toast = message
                    dismiss()
                }
            }
        }
        .presentationDetents(sizeClass == .compact ? [.medium, .large] : [.large])
        .presentationBackground(Theme.sheet)
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

    private func send(_ release: Release) {
        guard sendingID == nil else { return }
        sendingID = release.id
        let target = request.target ?? TransferTarget(
            tmdbID: 0, kind: release.parsed.season == nil ? .movie : .tv,
            title: release.parsed.title.isEmpty ? release.name : release.parsed.title,
            posterPath: nil, backdropPath: nil, season: release.parsed.season, episode: release.parsed.episode)
        Task {
            do {
                try await app.transfers.send(release, target: target)
                dismiss()
            } catch let refusal as NotEnoughSpace {
                roomOffer = refusal.offer
                sendingID = nil
            } catch {
                errorText = String(describing: error)
                sendingID = nil
            }
        }
    }
}

private struct FilterBar: View {
    @Bindable var model: VersionsModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: model.resolution == nil) { model.resolution = nil }
                ForEach(model.availableResolutions, id: \.self) { resolution in
                    chip(resolution == .uhd4320 ? "8K" : resolution == .uhd2160 ? "4K" : resolution.label, selected: model.resolution == resolution) {
                        model.resolution = resolution
                    }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selected ? .black : .white)
                .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SortMenu: View {
    @Bindable var model: VersionsModel

    var body: some View {
        Menu {
            Picker("Sort", selection: $model.sort) {
                Text("Seeders").tag(ReleaseSort.seeders)
                Text("Size").tag(ReleaseSort.size)
                Text("Quality").tag(ReleaseSort.quality)
            }
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
    }
}

struct ReleaseRow: View {
    let release: Release
    let inPutio: Bool
    let sending: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(release.parsed.resolution == .unknown ? "?" : (release.parsed.resolution == .uhd4320 ? "8K" : release.parsed.resolution == .uhd2160 ? "4K" : release.parsed.resolution.label))
                .font(.caption.monospaced().weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.45)))
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(release.name).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                FlowLayout(spacing: 5) {
                    ForEach(release.sources.sorted(), id: \.self) { tag in
                        Text(tag.label).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((tag.kind == .chill ? Color.red : Color.blue).opacity(0.22), in: Capsule())
                    }
                    ForEach(release.parsed.hdr, id: \.self) { flag in
                        Text(flag).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    if inPutio {
                        Text("IN PUT.IO").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.good.opacity(0.25), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Format.bytes(release.sizeBytes)).font(.caption.monospacedDigit())
                HStack(spacing: 4) {
                    Circle().fill(Theme.seeders(release.seeders)).frame(width: 7, height: 7)
                    Text(release.seeders.map(String.init) ?? "?").font(.caption.monospacedDigit())
                }
            }
            if sending { ProgressView().padding(.leading, 4) }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}
