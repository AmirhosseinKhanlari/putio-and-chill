import AMDBKit
import BackgroundTasks

enum BackgroundRefresh {
    static let identifier = "app.amdb.refresh"

    @MainActor static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated {
                schedule(every: model.settings.libraryUpdateMinutes)
                let work = Task {
                    await model.transfers.pollOnce()
                    // Keeps the cached library fresh, so the next launch shows new files right away.
                    await model.library.loadCached()
                    await model.refreshLibraryIfDue()
                    await model.episodeAlerts.load()
                    await EpisodeAlertScheduler.reschedule(model)
                }
                task.expirationHandler = { work.cancel() }
                Task {
                    await work.value
                    task.setTaskCompleted(success: true)
                }
            }
        }
    }

    /// iOS decides the actual time; transfers want frequent checks, the library its own interval.
    static func schedule(every libraryMinutes: Int = 60) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Double(min(libraryMinutes, 15)) * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
