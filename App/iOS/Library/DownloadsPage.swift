import AMDBCore
import AMDBKit
import SwiftUI

/// Everything saved on this device, grouped by movie or show: play offline, stream instead, or remove; with the space
/// each takes.
struct DownloadsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(OfflineDownloader.self) private var downloader
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var confirmRemoveAll = false
    @State private var removingGroup: DownloadGroup?

    var body: some View {
        let records = app.downloads.records
        let groups = DownloadGroup.groups(records)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ON THIS DEVICE").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.65))
                    Text("Downloads").font(.system(size: sizeClass == .compact ? 38 : 54, weight: .ultraLight)).tracking(3)
                    Text(summary(records)).font(.footnote).foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, sizeClass == .compact ? 44 : 70)

                preferenceCard

                if records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Nothing downloaded yet").font(.headline)
                        Text("Use the download button on a movie or episode that's in your put.io, or Download All in Files.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }

                ForEach(groups) { group in groupCard(group) }

                if records.count > 1 {
                    Button(role: .destructive) { confirmRemoveAll = true } label: {
                        Label("Remove All Downloads", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassPill)
                    .tint(Theme.poor)
                    .foregroundStyle(Theme.poor)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, sizeClass == .compact ? Metrics.tabBarInset(sizeClass) + 30 : 40)
        }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
        .alert("Remove all downloads from this device?", isPresented: $confirmRemoveAll) {
            Button("Remove All", role: .destructive) {
                Task { for record in records { await downloader.cancel(fileID: record.fileID) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(Format.bytes(totalBytes(records))). Your put.io files stay where they are.")
        }
        .alert(removingGroup.map { "Remove \($0.title) from this device?" } ?? "",
               isPresented: Binding(get: { removingGroup != nil }, set: { if !$0 { removingGroup = nil } })) {
            Button("Remove", role: .destructive) {
                guard let group = removingGroup else { return }
                Task { for record in group.records { await downloader.cancel(fileID: record.fileID) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let group = removingGroup {
                Text("\(group.records.count) download\(group.records.count == 1 ? "" : "s") · frees \(Format.bytes(totalBytes(group.records))). Your put.io files stay where they are.")
            }
        }
    }

    // MARK: Preference

    private var preferenceCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.good)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Play downloads when available").font(.subheadline.weight(.semibold))
                Text("Off: everything streams from put.io. Touch and hold Play on any title to choose each time.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Play downloads when available", isOn: Binding(get: { app.settings.preferDownloads }, set: { value in
                var settings = app.settings
                settings.preferDownloads = value
                app.updateSettings(settings)
            }))
            .labelsHidden()
            .tint(Theme.good)
        }
        .padding(16)
        .glassRounded(18)
    }

    // MARK: Groups

    private func groupCard(_ group: DownloadGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                RemoteImage(path: group.posterPath, size: "w185", seed: group.title)
                    .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title).font(.headline).lineLimit(1)
                    if group.isShow {
                        Text(groupDetail(group)).font(.caption).foregroundStyle(.white.opacity(0.6))
                    } else if let record = group.records.first {
                        Text(detail(record)).font(.caption).foregroundStyle(stateColor(record))
                    }
                }
                Spacer(minLength: 8)
                if group.isShow {
                    Menu {
                        if let tmdbID = group.tmdbID {
                            Button { router.open(CatalogItem(tmdbID: tmdbID, mediaType: .tv, title: group.title, posterPath: group.posterPath)) } label: {
                                Label("Go to Show", systemImage: "info.circle")
                            }
                        }
                        Button(role: .destructive) { removingGroup = group } label: {
                            Label("Remove All Episodes", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("More for \(group.title)")
                } else if let record = group.records.first {
                    controls(record, label: record.title)
                }
            }
            if group.isShow {
                ForEach(group.records) { record in
                    Divider().overlay(.white.opacity(0.08)).padding(.vertical, 2)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episodeLabel(record)).font(.subheadline.weight(.semibold))
                            Text(detail(record)).font(.caption).foregroundStyle(stateColor(record))
                        }
                        Spacer(minLength: 8)
                        controls(record, label: "\(record.title) \(episodeLabel(record))")
                    }
                    .padding(.leading, 58)
                }
            }
        }
        .padding(14)
        .glassRounded(18)
    }

    /// Play (offline), progress, or try again; ⋯ for streaming instead or removing.
    @ViewBuilder private func controls(_ record: DownloadRecord, label: String) -> some View {
        let done = if case .done = record.state { true } else { false }
        HStack(spacing: 4) {
            switch record.state {
            case .done:
                Button { play(record, .device) } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 30)).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(record.title) from this device")
            case let .downloading(progress):
                ProgressRing(progress: progress, lineWidth: 3).frame(width: 26, height: 26).frame(width: 44, height: 44)
            case .queued:
                ProgressView().frame(width: 44, height: 44)
            case .failed:
                Button { Task { await downloader.start(downloader.entry(for: record)) } } label: {
                    Image(systemName: "arrow.clockwise.circle").font(.system(size: 28)).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Try downloading \(record.title) again")
            }
            Menu {
                if done {
                    Button { play(record, .device) } label: { Label("Play from This Device", systemImage: "play.fill") }
                    Button { play(record, .stream) } label: { Label("Stream from put.io", systemImage: "icloud") }
                }
                Button(role: .destructive) { Task { await downloader.cancel(fileID: record.fileID) } } label: {
                    Label(done ? "Remove Download" : "Cancel Download", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("More for \(label)")
        }
    }

    // MARK: Text

    private func episodeLabel(_ record: DownloadRecord) -> String {
        switch (record.season, record.episode) {
        case let (season?, episode?): "Season \(season) · Episode \(episode)"
        case let (season?, nil): "Season \(season)"
        default: record.title
        }
    }

    private func detail(_ record: DownloadRecord) -> String {
        switch record.state {
        case .queued: "Waiting…"
        case let .downloading(progress): "Downloading \(Int(progress * 100))%"
        case .done: Format.bytes(downloader.size(fileID: record.fileID))
        case let .failed(message): message.hasPrefix("Stopped") ? message : "Failed: \(message)"
        }
    }

    private func stateColor(_ record: DownloadRecord) -> Color {
        if case .failed = record.state { return Theme.poor }
        return .white.opacity(0.6)
    }

    private func groupDetail(_ group: DownloadGroup) -> String {
        let count = group.isShow ? "\(group.records.count) episode\(group.records.count == 1 ? "" : "s")" : "Movie"
        let bytes = totalBytes(group.records)
        return bytes > 0 ? "\(count) · \(Format.bytes(bytes))" : count
    }

    private func totalBytes(_ records: [DownloadRecord]) -> Int64 {
        records.compactMap { downloader.size(fileID: $0.fileID) }.reduce(0, +)
    }

    private func summary(_ records: [DownloadRecord]) -> String {
        let done = app.downloads.finished
        if records.isEmpty { return "Empty" }
        return "\(done.count) ready to watch offline · \(Format.bytes(totalBytes(done)))"
    }

    private func play(_ record: DownloadRecord, _ source: PlaybackSource) {
        let entry = downloader.entry(for: record)
        router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry), source: source)
    }
}

/// Downloads of one movie, or all downloaded episodes of one show (in season and episode order).
private struct DownloadGroup: Identifiable {
    let id: String
    let title: String
    let posterPath: String?
    let tmdbID: Int?
    let isShow: Bool
    var records: [DownloadRecord]

    static func groups(_ records: [DownloadRecord]) -> [DownloadGroup] {
        var groups: [DownloadGroup] = []
        for record in records {
            let isShow = record.kind == .tv
            let key = isShow ? "tv-\(record.tmdbID.map(String.init) ?? record.title)" : "file-\(record.fileID)"
            if let index = groups.firstIndex(where: { $0.id == key }) {
                groups[index].records.append(record)
            } else {
                groups.append(DownloadGroup(id: key, title: record.title, posterPath: record.posterPath, tmdbID: record.tmdbID,
                                            isShow: isShow, records: [record]))
            }
        }
        return groups.map { group in
            var group = group
            group.records.sort { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
            return group
        }
    }
}
