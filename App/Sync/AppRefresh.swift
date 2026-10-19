import BackgroundTasks
import Foundation

/// BGAppRefresh: opportunistic (iOS decides when, typically a few times per day for engaged users).
/// Good enough to keep the 64-slot reminder window and the island fresh; not a real-time sync channel.
enum AppRefresh {
    /// "Not before": iOS picks the actual time.
    static let earliestInterval: TimeInterval = 15 * 60

    /// Registers the handler for `AppConstants.backgroundRefreshTaskID`. Call it once, from
    /// `application(_:didFinishLaunchingWithOptions:)`: BGTaskScheduler wants every launch handler registered before
    /// launch finishes and stops the app on a second registration. Not SwiftUI's `.backgroundTask(.appRefresh)`, which
    /// registers it with the scene: when iOS launched the app to run the Control Center button's intent (no scene
    /// yet), the app crashed as it opened (the same report in Apple's developer forums, thread 779354).
    static func registerHandler() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConstants.backgroundRefreshTaskID,
                                            using: nil) { task in
            let work = Task {
                await AppRefresh.run()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: AppConstants.backgroundRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Sends the outbox and lists each calendar's rolling window in full (`SyncTrigger.background`). Ranges loaded
    /// on demand are forgotten by it and listed again when the app next shows them (`ScheduleViewModel.ensureEvents`),
    /// so a background run stays a few requests per calendar. Calendar lists older than 6 hours are fetched again
    /// first (which also finishes moving a single-account sign-in, if that could not run yet). Demo mode syncs
    /// nothing.
    static func run() async {
        schedule()
        if !AppConstants.isDemoMode {
            await AccountManager.shared.refreshCalendarLists()
        }
        await SyncEngine.shared.sync(.background)
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
        // The notification extension's session for Smart Schedule's server, before it runs out.
        await AppAttestClient.shared.refreshSessionIfNeeded()
    }

    /// Call once at launch: a sync that changes the cache also refreshes the Live Activity (the engine reschedules
    /// reminders itself), and code without SyncEngine can ask for a sync (`SyncRequests`).
    static func installSyncHooks() {
        Task {
            await SyncEngine.shared.setChangeHandler {
                await ReminderScheduler.shared.reschedule()
                await LiveActivityManager.shared.refreshIfRunning()
            }
        }
        SyncRequests.install { trigger in
            _ = await SyncEngine.shared.sync(SyncTrigger(rawValue: trigger) ?? .summon)
        }
    }
}
