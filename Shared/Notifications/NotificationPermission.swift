import Foundation
import UserNotifications

/// When Smart Schedules asks for notification permission: once there is something to remind about (demo mode or a
/// connected Google account), never at first launch (Apple: ask "in a context that helps people understand why").
/// iOS shows its prompt once; later requests only return the answer.
enum NotificationPermission {
    /// No `.timeSensitive`: that option is deprecated since iOS 15.0 ("Use time-sensitive entitlement"). Time
    /// Sensitive reminders come from the Time Sensitive entitlement in project.yml
    /// (com.apple.developer.usernotifications.time-sensitive).
    static let options: UNAuthorizationOptions = [.alert, .sound, .badge]

    /// `hasCalendar`: signed in to Google, or in demo mode.
    static func shouldAsk(status: UNAuthorizationStatus, hasCalendar: Bool) -> Bool {
        hasCalendar && status == .notDetermined
    }
}
