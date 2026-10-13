import ActivityKit
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
        for entry in library.continueWatching.prefix(6) {
            let seconds = library.resumeSeconds(for: entry)
            var imageFile: String?
            if let url = CatalogClient.imageURL(entry.match?.posterPath, size: "w185"),
               let image = await ImagePipeline.shared.image(for: url),
               let data = image.jpegData(compressionQuality: 0.8) {
                let name = "poster-\(entry.id).jpg"
                try? data.write(to: container.appending(path: name), options: .atomic)
                imageFile = name
            }
            items.append(WidgetItem(id: String(entry.id), title: entry.displayTitle,
                                    subtitle: "Resume \(Format.clock(seconds))", imageFile: imageFile,
                                    link: DeepLink.play(fileID: entry.id).url))
        }
        WidgetSnapshot(continueWatching: items, updatedAt: .now).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueWatching")
    }
}

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
