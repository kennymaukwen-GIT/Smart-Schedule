import Foundation
import UserNotifications

/// Learns which default reminders the user keeps swiping away. `SS_EVENT_REMINDER` registers
/// `.customDismissAction`, so a dismissal reaches the app (`AppDelegate`) or the content extension like any other
/// response. Dismissed = +1 on that (kind, offset)'s streak; opening, snoozing or replying = back to 0. At five in a
/// row `PreferencesStore` creates a suggestion, which changes nothing until the user taps "Stop it".
enum ReminderEngagement {
    struct Outcome: Equatable, Sendable {
        var kind: ScheduleEvent.Kind
        var offsetMinutes: Int
        var isAllDay: Bool
        var dismissed: Bool
    }

    /// Call for every notification response; anything that is not a default-offset reminder is ignored.
    static func record(_ response: UNNotificationResponse, store: PreferencesStore = .shared) async {
        let request = response.notification.request
        guard let outcome = outcome(identifier: request.identifier,
                                    categoryIdentifier: request.content.categoryIdentifier,
                                    userInfo: request.content.userInfo,
                                    actionIdentifier: response.actionIdentifier) else { return }
        await store.recordReminderOutcome(kind: outcome.kind, offsetMinutes: outcome.offsetMinutes,
                                          isAllDay: outcome.isAllDay, dismissed: outcome.dismissed)
    }

    /// Pure part of `record` (a `UNNotificationResponse` cannot be built in tests). nil for briefings, nudges,
    /// follow-ups, snoozed copies and reminders the user set explicitly on an event.
    static func outcome(identifier: String,
                        categoryIdentifier: String,
                        userInfo: [AnyHashable: Any],
                        actionIdentifier: String) -> Outcome? {
        guard categoryIdentifier == NotificationIDs.Category.eventReminder,
              identifier.hasPrefix(NotificationIDs.reminderPrefix),
              !identifier.hasPrefix(NotificationIDs.snoozePrefix), // already engaged with once
              (userInfo[NotificationIDs.UserInfo.fromDefaults] as? Bool) == true,
              let rawKind = userInfo[NotificationIDs.UserInfo.kind] as? String,
              let kind = ScheduleEvent.Kind(rawValue: rawKind),
              let offset = (userInfo[NotificationIDs.UserInfo.offset] as? NSNumber)?.intValue else { return nil }
        let isAllDay = (userInfo[NotificationIDs.UserInfo.allDay] as? Bool) ?? false
        return Outcome(kind: kind, offsetMinutes: offset, isAllDay: isAllDay,
                       dismissed: actionIdentifier == UNNotificationDismissActionIdentifier)
    }
}
