#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import AMDBCore
import AMDBKit
import UIKit
import WidgetKit

/// Writes Continue Watching (titles + poster files) into the App Group for the Home Screen widget.
@MainActor
enum WidgetPublisher {
    static func publish(_ library: LibraryIndex) async {
        guard let container = AppGroup.container else { return }
        var items: [WidgetItem] = []
        var keep: Set<String> = []
        for entry in library.continueWatching.prefix(6) {
            let seconds = library.resumeSeconds(for: entry)
            let poster = await save(entry.match?.posterPath, size: "w342", as: "poster-\(entry.id)-w342.jpg", in: container)
            let backdrop = await save(entry.match?.backdropPath, size: "w780", as: "backdrop-\(entry.id)-w780.jpg", in: container)
            keep.formUnion([poster, backdrop].compactMap { $0 })
            items.append(WidgetItem(id: String(entry.id), title: entry.match?.title ?? entry.displayTitle,
                                    subtitle: "Resume \(Format.clock(seconds))", caption: caption(entry.match),
                                    imageFile: poster, backdropFile: backdrop,
                                    link: DeepLink.play(fileID: entry.id).url))
        }
        WidgetSnapshot(continueWatching: items, updatedAt: .now).save()
        removeStaleArtwork(in: container, keeping: keep)
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueWatching")
    }

    private static func caption(_ match: LibraryMatch?) -> String? {
        guard let match else { return nil }
        if let season = match.season, let episode = match.episode { return "S\(season) · E\(episode)" }
        if let season = match.season { return "Season \(season)" }
        return match.year.map(String.init)
    }

    /// Downloads artwork into the App Group; returns the file name, or nil when there's no art.
    private static func save(_ path: String?, size: String, as name: String, in container: URL) async -> String? {
        let file = container.appending(path: name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        guard let url = CatalogClient.imageURL(path, size: size),
              let image = await ImagePipeline.shared.image(for: url),
              let data = image.jpegData(compressionQuality: 0.82),
              (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return name
    }

    private static func removeStaleArtwork(in container: URL, keeping keep: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: container.path)) ?? []
        for name in files where (name.hasPrefix("poster-") || name.hasPrefix("backdrop-")) && !keep.contains(name) {
            try? FileManager.default.removeItem(at: container.appending(path: name))
        }
    }
}

#if targetEnvironment(macCatalyst)
/// macOS has no Live Activities: transfers show in the app (and in notifications) instead.
@MainActor
final class LiveActivityManager {
    func sync(_ tracked: [TrackedTransfer]) {}
}
#else
/// One Live Activity per active put.io transfer, updated from TransferMonitor.
/// Stores activity ids and looks activities up inside each task (Activity isn't Sendable).
@MainActor
final class LiveActivityManager {
    private var activityIDs: [Int64: String] = [:]

    func sync(_ tracked: [TrackedTransfer]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for transfer in tracked {
            let state = Self.state(for: transfer)
            if let activityID = activityIDs[transfer.id] {
                if transfer.notified {
                    activityIDs[transfer.id] = nil
                    Task { await Self.end(activityID, with: state) }
                } else {
                    Task { await Self.update(activityID, with: state) }
                }
            } else if !transfer.notified {
                let attributes = TransferActivityAttributes(title: transfer.pending.title, transferID: transfer.id)
                if let activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil)) {
                    activityIDs[transfer.id] = activity.id
                }
            }
        }
        for (transferID, activityID) in activityIDs where !tracked.contains(where: { $0.id == transferID }) {
            activityIDs[transferID] = nil
            Task { await Self.end(activityID, with: nil) }
        }
    }

    private nonisolated static func activity(_ id: String) -> Activity<TransferActivityAttributes>? {
        Activity<TransferActivityAttributes>.activities.first { $0.id == id }
    }

    private nonisolated static func update(_ id: String, with state: TransferActivityAttributes.ContentState) async {
        await activity(id)?.update(ActivityContent(state: state, staleDate: nil))
    }

    private nonisolated static func end(_ id: String, with state: TransferActivityAttributes.ContentState?) async {
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await activity(id)?.end(content, dismissalPolicy: state == nil ? .immediate : .after(.now.addingTimeInterval(30 * 60)))
    }

    private static func state(for transfer: TrackedTransfer) -> TransferActivityAttributes.ContentState {
        let ready = transfer.playableFile != nil
        let detail = [Format.speed(transfer.transfer?.downSpeed), Format.eta(transfer.transfer?.estimatedTime)]
            .compactMap { $0 }.joined(separator: " · ")
        let status: String = switch transfer.phase {
        case .queued: "Queued"
        case .finishing: "Finishing"
        case .failed: "Failed"
        default: "Downloading"
        }
        return .init(percent: ready ? 100 : transfer.percent, status: status,
                     detail: detail.isEmpty ? status : detail, isReady: ready,
                     link: transfer.playableFile.map { DeepLink.play(fileID: $0.id).url })
    }
}
#endif
