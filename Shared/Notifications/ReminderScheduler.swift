import Foundation
import UserNotifications

/// Schedules Smart Schedule's own notifications from the shared cache and Settings › Notifications: interactive
/// event reminders (Artboard 1), the morning briefing and evening preview, and plan nudges.
///
/// iOS keeps at most 64 pending local notifications per app and silently drops the rest, so this is a rolling
/// window (`ReminderPlanner`): re-run after every write, sync, app launch, background refresh and preference change.
/// "Google Calendar only" schedules no reminders; briefings and nudges stay.
actor ReminderScheduler {
    static let shared = ReminderScheduler()

    private let center = UNUserNotificationCenter.current()

    func reschedule(store: SharedStore = .shared, now: Date = Date()) async {
        let preferences = PreferencesStore.shared.current()
        let clock = WallClock(timeZone: preferences.timeZone, firstWeekday: preferences.firstWeekday)
        let nudges = await store.snapshot().nudges
        var reminderEvents: [ScheduleEvent] = []
        if preferences.localRemindersEnabled {
            reminderEvents = await store.visibleEvents(audience: .reminders)
        }
        let today = clock.calendar.startOfDay(for: now)
        let briefingRange = DateInterval(start: today, duration: Double(ReminderPlanner.briefingDays + 2) * 86_400)
        let briefingEvents = await store.visibleEvents(in: briefingRange, audience: .display)

        let plan = ReminderPlanner.plan(reminderEvents: reminderEvents, briefingEvents: briefingEvents, nudges: nudges,
                                        preferences: preferences, now: now, clock: clock)

        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter(Self.isRescheduled))

        for nudge in plan.nudges {
            try? await center.add(Self.nudgeRequest(nudge))
        }
        for briefing in plan.briefings {
            try? await center.add(Self.briefingRequest(briefing))
        }
        for reminder in plan.reminders {
            try? await center.add(Self.request(for: reminder, clock: clock))
        }
    }

    /// Erase: every pending request of this app, snoozes included.
    func removeAll() async {
        center.removeAllPendingNotificationRequests()
    }

    /// Re-posts the same content later. Usable from the notification content extension.
    static func snooze(_ content: UNNotificationContent, minutes: Int) async {
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else { return }
        copy.subtitle = String(localized: "Snoozed \(minutes) min")
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        let request = UNNotificationRequest(identifier: NotificationIDs.snoozePrefix + UUID().uuidString,
                                            content: copy, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Reminders (not snoozes), nudges and briefings: everything a reschedule replaces.
    static func isRescheduled(_ identifier: String) -> Bool {
        (identifier.hasPrefix(NotificationIDs.reminderPrefix) && !identifier.hasPrefix(NotificationIDs.snoozePrefix))
            || identifier.hasPrefix(NotificationIDs.nudgePrefix)
            || identifier.hasPrefix(NotificationIDs.briefingPrefix)
    }

    // MARK: - Builders

    static func request(for reminder: PlannedReminder, clock: WallClock) -> UNNotificationRequest {
        let event = reminder.event
        let content = UNMutableNotificationContent()
        content.title = event.title
        let place = event.location ?? (event.meetURL != nil ? "Google Meet" : nil)
        let when: String
        if reminder.isAllDay {
            content.subtitle = allDayLeadText(reminder.minutes)
            when = [String(localized: "All day"), place].compactMap { $0 }.joined(separator: " · ")
        } else {
            content.subtitle = leadText(reminder.minutes)
            when = [ReplyFormatter.clockTime(event.start, clock: clock), place].compactMap { $0 }.joined(separator: " · ")
        }
        content.body = when + "\n" + holdHint
        content.categoryIdentifier = NotificationIDs.Category.eventReminder
        content.threadIdentifier = event.id
        content.userInfo = [
            NotificationIDs.UserInfo.eventID: event.id,
            NotificationIDs.UserInfo.kind: event.kind.rawValue,
            NotificationIDs.UserInfo.offset: reminder.minutes,
            NotificationIDs.UserInfo.allDay: reminder.isAllDay,
            NotificationIDs.UserInfo.fromDefaults: reminder.fromDefaults
        ]
        // .timeSensitive needs the Time Sensitive entitlement and breaks through Focus; .passive arrives silently.
        content.interruptionLevel = reminder.level
        content.relevanceScore = ReminderPlanner.relevanceScore(reminder.level)
        content.sound = reminder.level == .passive ? nil : .default
        return UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger(at: reminder.fire))
    }

    /// A reminder's last line: what holding it down offers (typing a change in the expanded card, Snooze 10 min).
    static var holdHint: String { String(localized: "Hold to edit or snooze") }

    /// A reminder's body without its hold hint, for the expanded card's header (the hint is the last line; it is
    /// also left out when it was written in English or in Chinese before the language changed).
    static func bodyWithoutHoldHint(_ body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        let hints: Set<String> = [holdHint, "Hold to edit or snooze", "長按以編輯或延後行程"]
        if let last = lines.last, hints.contains(last) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    static func briefingRequest(_ briefing: PlannedBriefing) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = briefing.content.title
        content.body = briefing.content.body
        content.categoryIdentifier = NotificationIDs.Category.compose // long-press to reply in place
        content.threadIdentifier = NotificationIDs.briefingThread
        content.userInfo = [NotificationIDs.UserInfo.briefingDay: briefing.describedDay]
        content.interruptionLevel = briefing.isQuiet ? .passive : .active
        content.relevanceScore = ReminderPlanner.relevanceScore(content.interruptionLevel)
        content.sound = nil // a summary, not an alarm
        return UNNotificationRequest(identifier: briefing.identifier, content: content, trigger: trigger(at: briefing.fire))
    }

    static func nudgeRequest(_ nudge: PlanNudge) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Smart Schedules"
        content.body = nudge.message
        content.categoryIdentifier = NotificationIDs.Category.compose // reply "skip today" in place
        content.userInfo = [NotificationIDs.UserInfo.planID: nudge.planID]
        content.interruptionLevel = .passive
        // Repeating triggers cannot carry an end date; rescheduling drops the nudge after `endsOn`.
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: nudge.hour, minute: nudge.minute), repeats: true)
        return UNNotificationRequest(identifier: NotificationIDs.nudgePrefix + nudge.planID, content: content, trigger: trigger)
    }

    /// The device calendar turns the absolute instant into components, so a fixed time zone in Settings still
    /// fires at the right moment.
    private static func trigger(at fire: Date) -> UNCalendarNotificationTrigger {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    static func leadText(_ minutes: Int) -> String {
        switch minutes {
        case 0: String(localized: "Starting now")
        case 1..<60: String(localized: "In \(minutes) min")
        case 60..<1440: String(localized: "In \(minutes / 60) h")
        case 1440..<2880: String(localized: "Tomorrow")
        default: String(localized: "In \(minutes / 1440) days")
        }
    }

    /// All-day reminders count back from 00:00 of the event day: 900 fires the day before, so "Tomorrow".
    static func allDayLeadText(_ minutes: Int) -> String {
        switch (max(0, minutes) + 1439) / 1440 {
        case 0: String(localized: "Today")
        case 1: String(localized: "Tomorrow")
        case let days: String(localized: "In \(days) days")
        }
    }
}
