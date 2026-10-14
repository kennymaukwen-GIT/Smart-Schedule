import BackgroundTasks
import Foundation

/// BGAppRefresh: opportunistic (iOS decides when, typically a few times per day for engaged users).
/// Good enough to keep the 64-slot reminder window and the island fresh; not a real-time sync channel.
enum AppRefresh {
    /// "Not before": iOS picks the actual time.
    static let earliestInterval: TimeInterval = 15 * 60

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
    }

    /// Call once at launch: a sync that changes the cache also refreshes the Live Activity (the engine reschedules
    /// reminders itself), and the Control Center summon, which iOS runs in this process, syncs before it shows the
    /// island (`SyncRequests.request("summon")`).
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
