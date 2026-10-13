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

    static func run() async {
        schedule()
        try? await CalendarSync().refreshWindow()
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
    }
}
