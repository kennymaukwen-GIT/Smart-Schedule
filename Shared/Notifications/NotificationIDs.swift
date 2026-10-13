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
    }

    static let reminderPrefix = "ss.reminder."
    static let nudgePrefix = "ss.nudge."

    /// Call at every launch (app) — categories are per-app, not per-process.
    static func registerCategories() {
        // The system text field is the guaranteed input path inside an expanded notification:
        // it works on the Lock Screen and the result is delivered to the content extension in place.
        let reply = UNTextInputNotificationAction(
            identifier: Action.reply,
            title: "Type in any plan to add or change",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "text.bubble"),
            textInputButtonTitle: "Send",
            textInputPlaceholder: "e.g. push this to 4pm · add gym tomorrow 7am"
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze10,
            title: "Snooze 10 min",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "zzz")
        )
        let reminder = UNNotificationCategory(
            identifier: Category.eventReminder,
            actions: [reply, snooze],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Upcoming event",
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
