import AMDBKit
import BackgroundTasks

enum BackgroundRefresh {
    static let identifier = "app.amdb.refresh"

    @MainActor static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated {
                schedule()
                let work = Task { await model.transfers.pollOnce() }
                task.expirationHandler = { work.cancel() }
                Task {
                    await work.value
                    task.setTaskCompleted(success: true)
                }
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
