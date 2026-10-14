import AMDBCore
import AMDBKit
import SwiftUI

/// "360 GB of 1 TB used" bar for put.io. Asks put.io again whenever it appears, after every library update
/// (pull to refresh, Update Now, automatic) and after file changes, so it never shows an old number.
struct StorageMeter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // A frame that always exists, so .task runs even before there's anything to show.
        VStack(alignment: .leading) {
            if let disk = app.storage.disk {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.1))
                            Capsule().fill(disk.fractionUsed > 0.9 ? Theme.poor : .white.opacity(0.85))
                                .frame(width: proxy.size.width * min(1, disk.fractionUsed))
                        }
                    }
                    .frame(height: 6)
                    Text(line(disk)).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: 420, minHeight: 4, alignment: .leading)
        .task { await app.storage.refresh() }
        .onChange(of: app.library.lastUpdated) { _, _ in Task { await app.storage.refresh() } }
    }

    private func line(_ disk: PutioAccount.Disk) -> String {
        var text = "put.io: \(Format.bytes(disk.used)) of \(Format.bytes(disk.size)) used · \(Format.bytes(disk.avail)) free"
        if app.storage.trashSize > 0 { text += " · \(Format.bytes(app.storage.trashSize)) in Trash" }
        return text
    }
}

/// Download / remove-download control for a playable entry.
struct DownloadButton: View {
    let entry: LibraryEntry
    var iconOnly = true
    /// Bare icon (episode rows) instead of a glass pill.
    var plain = false
    @Environment(AppModel.self) private var app
    @Environment(OfflineDownloader.self) private var downloader
    @State private var showUnsupported = false

    var body: some View {
        let state = app.downloads.record(fileID: entry.id)?.state
        Button {
            Task {
                switch state {
                case .done?, .downloading?, .queued?: await downloader.cancel(fileID: entry.id)
                default:
                    if OfflineDownloader.isSupported { await downloader.start(entry) } else { showUnsupported = true }
                }
            }
        } label: {
            if case let .converting(percent)? = app.conversions.states[entry.id], state != nil {
                // put.io is converting it for Apple devices; the download starts when that's done.
                ProgressRing(progress: Double(percent) / 100, lineWidth: 3)
                    .overlay { Image(systemName: "gearshape.fill").font(.system(size: plain ? 9 : 7)) }
                    .frame(width: plain ? 26 : 20, height: plain ? 26 : 20)
            } else {
                stateIcon(state)
            }
        }
        .buttonStyle(DownloadButtonStyle(plain: plain))
        .accessibilityLabel(label(state))
        .alert("Downloads need a real device", isPresented: $showUnsupported) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Apple's offline video downloads don't run in the Simulator. On your iPad or iPhone this saves the video for offline viewing.")
        }
    }

    @ViewBuilder private func stateIcon(_ state: DownloadState?) -> some View {
        switch state {
        case let .downloading(progress)?:
            ProgressRing(progress: progress, lineWidth: 3).frame(width: plain ? 26 : 20, height: plain ? 26 : 20)
        case .queued?:
            ProgressView().controlSize(.small)
        case .done?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                .font(plain ? .system(size: 28) : .body)
        default:
            if plain {
                Image(systemName: "arrow.down.to.line.circle").font(.system(size: 28, weight: .light))
            } else if iconOnly {
                Image(systemName: "arrow.down.to.line")
            } else {
                Label("Download", systemImage: "arrow.down.to.line")
            }
        }
    }

    private struct DownloadButtonStyle: ButtonStyle {
        let plain: Bool
        func makeBody(configuration: Configuration) -> some View {
            if plain {
                AnyView(LiftStyle().makeBody(configuration: configuration))
            } else {
                AnyView(GlassPillStyle().makeBody(configuration: configuration))
            }
        }
    }

    private func label(_ state: DownloadState?) -> String {
        if case let .converting(percent)? = app.conversions.states[entry.id], state != nil {
            return "put.io is converting this video for Apple devices, \(percent)%. Tap to cancel"
        }
        return switch state {
        case .done?: "Downloaded. Tap to remove"
        case .downloading?, .queued?: "Downloading. Tap to cancel"
        default: "Download to this device"
        }
    }
}

/// First auto-clean: show what will be deleted before anything is.
struct AutoCleanReview: View {
    let entries: [LibraryEntry]
    let onConfirm: () -> Void
    let onSkip: () -> Void

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                HStack(spacing: 12) {
                    RemoteImage(path: entry.match?.posterPath, size: "w185", seed: entry.displayTitle)
                        .frame(width: 36, height: 54).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading) {
                        Text(entry.displayTitle).font(.subheadline.weight(.semibold))
                        Text(Format.bytes(entry.file.size)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheet)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Text("These movies were finished in Putio & Chill a while ago. They'll be deleted from put.io; future cleanups happen automatically.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(role: .destructive, action: onConfirm) {
                        Text("Delete \(entries.count) movie\(entries.count == 1 ? "" : "s")").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.poor)
                    Button("Not now", action: onSkip)
                }
                .padding()
                .background(Theme.sheet)
            }
            .navigationTitle("Auto-clean")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationBackground(Theme.sheet)
    }
}
