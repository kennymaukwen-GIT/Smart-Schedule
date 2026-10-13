import BackgroundTasks
import Foundation

/// BGAppRefresh: opportunistic (iOS decides when, typically a few times per day for engaged users).
/// Good enough to keep the 64-slot reminder window and the island fresh; not a real-time sync channel.
enum AppRefresh {
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: AppConstants.backgroundRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Only the rolling window of each calendar is re-listed here. Ranges loaded on demand are forgotten by it and
    /// listed again when the app next shows them (`ScheduleViewModel.ensureEvents`), so a background run stays a
    /// few requests per calendar. Calendar lists older than 6 hours are fetched again first (which also finishes
    /// moving a single-account sign-in, if that could not run yet).
    static func run() async {
        schedule()
        // Demo data lives only in the cache; a Google listing must not replace the seeded window (same as refresh()).
        if !AppConstants.isDemoMode {
            await AccountManager.shared.refreshCalendarLists()
            try? await CalendarSync().refreshWindow()
        }
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
    }
}
