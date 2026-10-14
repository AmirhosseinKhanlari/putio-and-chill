import AMDBCore
import AMDBKit
import SwiftUI

/// Everything saved on this device: play (offline), stream instead, or remove; with the space each takes.
struct DownloadsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(OfflineDownloader.self) private var downloader
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var confirmRemoveAll = false

    var body: some View {
        let records = app.downloads.records
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ON THIS DEVICE").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.65))
                    Text("Downloads").font(.system(size: sizeClass == .compact ? 38 : 54, weight: .ultraLight)).tracking(3)
                    Text(summary(records)).font(.footnote).foregroundStyle(.white.opacity(0.55))
                }
                .listRowBackground(Color.clear)
                Toggle("Play downloads when available", isOn: Binding(get: { app.settings.preferDownloads }, set: { value in
                    var settings = app.settings
                    settings.preferDownloads = value
                    app.updateSettings(settings)
                }))
                .tint(Theme.good)
            } footer: {
                Text("When off, everything streams from put.io. Long-press Play on any title to choose each time.")
            }
            if records.isEmpty {
                Text("Nothing downloaded. Use the download button on a movie or episode that's in your put.io.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(records) { record in row(record) }
                    .onDelete { offsets in
                        let doomed = offsets.map { records[$0].fileID }
                        Task { for id in doomed { await downloader.cancel(fileID: id) } }
                    }
            }
            if records.count > 1 {
                Section {
                    Button("Remove All Downloads", role: .destructive) { confirmRemoveAll = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .ambientBackground()
        .confirmationDialog("Remove all downloads from this device?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                Task { for record in records { await downloader.cancel(fileID: record.fileID) } }
            }
        } message: {
            Text("Your put.io files stay where they are.")
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        let done = if case .done = record.state { true } else { false }
        return HStack(spacing: 14) {
            RemoteImage(path: record.posterPath, size: "w185", seed: record.title)
                .frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(detail(record)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if done {
                Button { play(record, .device) } label: { Image(systemName: "play.circle.fill").font(.system(size: 30)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(record.title) from this device")
            } else if case let .downloading(progress) = record.state {
                ProgressRing(progress: progress, lineWidth: 3).frame(width: 26, height: 26)
            } else {
                ProgressView()
            }
        }
        .contextMenu {
            if done {
                Button { play(record, .device) } label: { Label("Play from This Device", systemImage: "play.fill") }
                Button { play(record, .stream) } label: { Label("Stream from put.io", systemImage: "icloud") }
            }
            Button(role: .destructive) { Task { await downloader.cancel(fileID: record.fileID) } } label: {
                Label(done ? "Remove Download" : "Cancel Download", systemImage: "trash")
            }
        }
    }

    private func detail(_ record: DownloadRecord) -> String {
        let episode = record.season.map { season in "S\(season)" + (record.episode.map { " E\($0)" } ?? "") }
        let state: String = switch record.state {
        case .queued: "Waiting…"
        case let .downloading(progress): "Downloading \(Int(progress * 100))%"
        case .done: Format.bytes(downloader.size(fileID: record.fileID))
        case let .failed(message): "Failed: \(message)"
        }
        return [episode, state].compactMap { $0 }.joined(separator: " · ")
    }

    private func summary(_ records: [DownloadRecord]) -> String {
        let done = app.downloads.finished
        let total = done.compactMap { downloader.size(fileID: $0.fileID) }.reduce(0, +)
        if records.isEmpty { return "Empty" }
        return "\(done.count) ready to watch offline · \(Format.bytes(total))"
    }

    private func play(_ record: DownloadRecord, _ source: PlaybackSource) {
        let entry = downloader.entry(for: record)
        router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry), source: source)
    }
}
