import Foundation
import UserNotifications

/// Schedules Smart Schedule's own interactive reminders (Artboard 1) from the shared cache.
///
/// iOS keeps at most 64 pending local notifications per app and silently drops the rest, so this is a
/// rolling window: soonest triggers first, re-run after every write, app launch and background refresh.
/// 4 offsets × N events exhausts 64 fast — that is why routines only get one ping by default.
actor ReminderScheduler {
    static let shared = ReminderScheduler()
    private static let pendingLimit = 64

    private let center = UNUserNotificationCenter.current()
    private let policy = ReminderPolicy()

    func reschedule(store: SharedStore = .shared, now: Date = Date()) async {
        guard AppConstants.localRemindersEnabled else { return }
        let snapshot = await store.snapshot()
        let activeNudges = snapshot.nudges.filter { $0.endsOn > now }

        var candidates: [(fire: Date, event: ScheduleEvent, minutes: Int)] = []
        for event in snapshot.events where !event.isAllDay && event.start > now && !event.isCompleted {
            let offsets = event.reminderMinutes ?? policy.defaults(for: event.kind)
            for minutes in Set(offsets) {
                let fire = event.start.addingTimeInterval(-Double(minutes) * 60)
                if fire > now { candidates.append((fire, event, minutes)) }
            }
        }
        candidates.sort { $0.fire < $1.fire }
        let budget = max(0, Self.pendingLimit - activeNudges.count - 2) // 2 slots spare for snoozes
        let chosen = candidates.prefix(budget)

        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter {
            $0.hasPrefix(NotificationIDs.reminderPrefix) || $0.hasPrefix(NotificationIDs.nudgePrefix)
        }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        for item in chosen {
            try? await center.add(request(for: item.event, minutes: item.minutes, fire: item.fire))
        }
        for nudge in activeNudges {
            try? await center.add(nudgeRequest(nudge))
        }
    }

    /// Re-posts the same content later. Usable from the notification content extension.
    static func snooze(_ content: UNNotificationContent, minutes: Int) async {
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else { return }
        copy.subtitle = String(localized: "Snoozed \(minutes) min")
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        let request = UNNotificationRequest(identifier: NotificationIDs.reminderPrefix + "snooze." + UUID().uuidString,
                                            content: copy, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Builders

    private func request(for event: ScheduleEvent, minutes: Int, fire: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.subtitle = Self.leadText(minutes)
        let time = ReplyFormatter.clockTime(event.start, clock: WallClock())
        content.body = [time, event.location ?? (event.meetURL != nil ? "Google Meet" : nil)]
            .compactMap { $0 }.joined(separator: " · ")
        content.categoryIdentifier = NotificationIDs.Category.eventReminder
        content.threadIdentifier = event.id
        content.userInfo = [NotificationIDs.UserInfo.eventID: event.id]
        content.sound = .default
        // Needs the Time Sensitive entitlement; breaks through Focus for imminent meetings only.
        content.interruptionLevel = minutes <= 30 ? .timeSensitive : .active
        content.relevanceScore = minutes <= 30 ? 1.0 : 0.5

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        return UNNotificationRequest(
            identifier: "\(NotificationIDs.reminderPrefix)\(event.id).\(minutes)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
    }

    private func nudgeRequest(_ nudge: PlanNudge) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Smart Schedule"
        content.body = nudge.message
        content.categoryIdentifier = NotificationIDs.Category.compose // reply "skip today" in place
        content.userInfo = [NotificationIDs.UserInfo.planID: nudge.planID]
        content.interruptionLevel = .passive
        // Repeating triggers cannot carry an end date; rescheduling drops the nudge after `endsOn`.
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: nudge.hour, minute: nudge.minute), repeats: true)
        return UNNotificationRequest(identifier: NotificationIDs.nudgePrefix + nudge.planID, content: content, trigger: trigger)
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
}
