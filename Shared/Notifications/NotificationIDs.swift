import Foundation
import UserNotifications

/// Categories handled by the Notification Content Extension (listed in its Info.plist
/// `UNNotificationExtensionCategory`). Only notifications *this app* delivers can use them —
/// iOS never lets an app extend another app's notifications (e.g. the Google Calendar app's).
enum NotificationIDs {
    enum Category {
        static let eventReminder = "SS_EVENT_REMINDER"
        static let compose = "SS_COMPOSE"
    }

    enum Action {
        static let reply = "SS_REPLY"
        static let snooze10 = "SS_SNOOZE_10"
    }

    enum UserInfo {
        static let eventID = "ssEventId"
        static let planID = "ssPlanId"
        /// Reminders: `ScheduleEvent.Kind` raw value, offset in minutes (all-day: before 00:00 of the event day),
        /// whether the event is all-day, and whether the offset came from the kind's defaults (only those feed
        /// the dismiss learning).
        static let kind = "ssKind"
        static let offset = "ssOffset"
        static let allDay = "ssAllDay"
        static let fromDefaults = "ssFromDefaults"
        /// Briefings: the day the briefing describes, "yyyy-MM-dd".
        static let briefingDay = "ssBriefingDay"
        /// Follow-ups presenting an "Ask me first" batch (`PendingEventBatch.id`).
        static let pendingBatchID = "ssPendingBatchId"
    }

    static let reminderPrefix = "ss.reminder."
    /// Snoozed copies: `ss.reminder.snooze.<uuid>`. Rescheduling leaves them alone.
    static let snoozePrefix = "ss.reminder.snooze."
    static let nudgePrefix = "ss.nudge."
    /// `ss.briefing.morning.<yyyy-MM-dd>` / `ss.briefing.evening.<yyyy-MM-dd>`, dated by the delivery day.
    static let briefingPrefix = "ss.briefing."
    static let briefingThread = "ss.briefing"

    /// Call at every launch (app) — categories are per-app, not per-process.
    static func registerCategories() {
        // The system text field is the guaranteed input path inside an expanded notification:
        // it works on the Lock Screen and the result is delivered to the content extension in place.
        let reply = UNTextInputNotificationAction(
            identifier: Action.reply,
            title: String(localized: "Type in any plan to add or change"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "text.bubble"),
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "e.g. push this to 16:00 · add gym tomorrow 07:00")
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze10,
            title: String(localized: "Snooze 10 min"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "zzz")
        )
        // customDismissAction: swiping a reminder away reaches the app (`ReminderEngagement`), which learns
        // which default reminders the user keeps ignoring.
        let reminder = UNNotificationCategory(
            identifier: Category.eventReminder,
            actions: [reply, snooze],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: String(localized: "Upcoming event"),
            options: [.customDismissAction]
        )
        let compose = UNNotificationCategory(
            identifier: Category.compose,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([reminder, compose])
    }
}
