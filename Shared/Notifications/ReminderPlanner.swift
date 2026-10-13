import Foundation
import UserNotifications

/// One reminder `ReminderScheduler` adds.
struct PlannedReminder: Hashable, Sendable {
    var event: ScheduleEvent
    /// Minutes before the start; all-day: minutes before 00:00 of the event day.
    var minutes: Int
    var isAllDay: Bool
    /// The offset came from the kind's defaults (`event.reminderMinutes == nil`); only these feed dismiss learning.
    var fromDefaults: Bool
    var fire: Date
    var level: UNNotificationInterruptionLevel

    var identifier: String { NotificationIDs.reminderPrefix + "\(event.id).\(minutes)" }
}

/// One morning briefing or evening preview, its text built at schedule time.
struct PlannedBriefing: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case morning, evening }

    var kind: Kind
    /// Start of the day it is delivered on (the identifier's date).
    var deliveryDay: Date
    /// "yyyy-MM-dd" of the day it describes: the delivery day (morning) or the next day (evening).
    var describedDay: String
    var fire: Date
    var content: BriefingBuilder.Content
    /// Inside quiet hours: delivered as passive.
    var isQuiet: Bool
    var identifier: String
}

struct ReminderPlan: Sendable {
    var reminders: [PlannedReminder] = []
    var nudges: [PlanNudge] = []
    var briefings: [PlannedBriefing] = []
    /// Reminders the daily cap held back, by the local day they would have fired ("yyyy-MM-dd").
    var capped: [String: [PlannedReminder]] = [:]

    var requestCount: Int { reminders.count + nudges.count + briefings.count }
}

/// Pure planning behind `ReminderScheduler`: which reminders, briefings and nudges to schedule, how loudly, within
/// iOS's limit of 64 pending requests. No I/O, so every rule is unit-tested.
///
/// Budget order: 2 spare slots (snoozes), active plan nudges, briefings, then reminders soonest first. The daily
/// cap is applied before the budget; briefings and nudges never count towards it.
enum ReminderPlanner {
    /// iOS keeps at most 64 pending local notifications per app and silently drops the rest.
    static let pendingLimit = 64
    /// Left free for snoozes, which are added between reschedules.
    static let spareSlots = 2
    /// Briefings for today (when still ahead), tomorrow and the day after: at most 6 requests.
    static let briefingDays = 3

    /// - Parameters:
    ///   - reminderEvents: visible events of calendars whose notifications are on (`EventAudience.reminders`).
    ///   - briefingEvents: visible events (`EventAudience.display`).
    static func plan(reminderEvents: [ScheduleEvent],
                     briefingEvents: [ScheduleEvent],
                     nudges: [PlanNudge],
                     preferences: AppPreferences,
                     now: Date,
                     clock: WallClock) -> ReminderPlan {
        var free = pendingLimit - spareSlots
        let activeNudges = Array(nudges.filter { $0.endsOn > now }.prefix(max(0, free)))
        free -= activeNudges.count

        let all = preferences.localRemindersEnabled
            ? candidates(events: reminderEvents, preferences: preferences, now: now, clock: clock)
            : []
        let (kept, capped) = applyCap(all, cap: preferences.dailyReminderCap, clock: clock)

        let briefings = Array(self.briefings(events: briefingEvents, capped: capped, preferences: preferences,
                                             now: now, clock: clock).prefix(max(0, free)))
        free -= briefings.count

        let reminders = Array(kept.sorted(by: soonestFirst).prefix(max(0, free)))
        return ReminderPlan(reminders: reminders, nudges: activeNudges, briefings: briefings, capped: capped)
    }

    // MARK: Reminders

    /// Every future reminder: `event.reminderMinutes ?? the kind's defaults` for timed events,
    /// `event.reminderMinutes ?? the all-day default` for all-day events. Completed, past and draft events get none.
    static func candidates(events: [ScheduleEvent],
                           preferences: AppPreferences,
                           now: Date,
                           clock: WallClock) -> [PlannedReminder] {
        let policy = ReminderPolicy(preferences: preferences)
        var result: [PlannedReminder] = []
        for event in events where !event.isCompleted && !event.isDraft {
            let fromDefaults = event.reminderMinutes == nil
            let offsets = event.isAllDay
                ? (event.reminderMinutes ?? policy.allDayDefaults)
                : (event.reminderMinutes ?? policy.defaults(for: event.kind))
            for minutes in Set(offsets.map { max(0, $0) }) {
                let fire: Date?
                if event.isAllDay {
                    fire = allDayFireDate(eventStart: event.start, minutes: minutes, clock: clock)
                } else {
                    fire = event.start.addingTimeInterval(-Double(minutes) * 60)
                }
                guard let fire, fire > now else { continue }
                result.append(PlannedReminder(event: event, minutes: minutes, isAllDay: event.isAllDay,
                                              fromDefaults: fromDefaults, fire: fire,
                                              level: level(kind: event.kind, minutes: minutes, fire: fire,
                                                           preferences: preferences, clock: clock)))
            }
        }
        return result
    }

    /// Counted in wall-clock days and time, so 900 is always the day before at 09:00, whatever DST does between.
    static func allDayFireDate(eventStart: Date, minutes: Int, clock: WallClock) -> Date? {
        let calendar = clock.calendar
        let minutes = max(0, minutes)
        let daysBefore = (minutes + 1439) / 1440
        let minuteOfDay = daysBefore * 1440 - minutes
        guard let day = calendar.date(byAdding: .day, value: -daysBefore, to: calendar.startOfDay(for: eventStart)) else {
            return nil
        }
        return clock.combine(day: day, time: (hour: minuteOfDay / 60, minute: minuteOfDay % 60))
    }

    /// Quiet hours first (passive, whatever the urgency; nothing is dropped), then the kind's urgency.
    /// `automatic` is the original rule: Time Sensitive at 30 minutes or less before the start.
    static func level(kind: ScheduleEvent.Kind,
                      minutes: Int,
                      fire: Date,
                      preferences: AppPreferences,
                      clock: WallClock) -> UNNotificationInterruptionLevel {
        if preferences.quietHours.contains(minuteOfDay: minuteOfDay(fire, clock: clock)) { return .passive }
        switch preferences.urgency(for: kind) {
        case .automatic: return minutes <= 30 ? .timeSensitive : .active
        case .timeSensitive: return .timeSensitive
        case .normal: return .active
        case .quiet: return .passive
        }
    }

    static func relevanceScore(_ level: UNNotificationInterruptionLevel) -> Double {
        switch level {
        case .timeSensitive, .critical: 1.0
        case .passive: 0.2
        default: 0.5
        }
    }

    static func minuteOfDay(_ date: Date, clock: WallClock) -> Int {
        let parts = clock.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    // MARK: Daily cap

    /// Lower is kept first: start pings, deadlines, other event reminders, tasks, routines. All-day reminders take
    /// their kind's class.
    static func priority(_ reminder: PlannedReminder) -> Int {
        switch reminder.event.kind {
        case .event: (!reminder.isAllDay && reminder.minutes == 0) ? 0 : 2
        case .deadline: 1
        case .task: 3
        case .routine: 4
        }
    }

    /// Per local day of the fire time, keeps the `cap` best by priority (ties: earlier first). The rest is
    /// returned by day so that day's morning briefing can list it.
    static func applyCap(_ reminders: [PlannedReminder],
                         cap: Int?,
                         clock: WallClock) -> (kept: [PlannedReminder], capped: [String: [PlannedReminder]]) {
        guard let cap else { return (reminders, [:]) }
        var kept: [PlannedReminder] = []
        var capped: [String: [PlannedReminder]] = [:]
        for (day, items) in Dictionary(grouping: reminders, by: { clock.dateString($0.fire) }) {
            let ranked = items.sorted { (priority($0), $0.fire, $0.identifier) < (priority($1), $1.fire, $1.identifier) }
            kept += ranked.prefix(cap)
            let overflow = ranked.dropFirst(cap)
            if !overflow.isEmpty { capped[day] = overflow.sorted(by: soonestFirst) }
        }
        return (kept, capped)
    }

    static func soonestFirst(_ lhs: PlannedReminder, _ rhs: PlannedReminder) -> Bool {
        (lhs.fire, lhs.identifier) < (rhs.fire, rhs.identifier)
    }

    // MARK: Briefings

    /// Morning briefings and evening previews for `briefingDays` delivery days, soonest first. Content is built now
    /// and rebuilt on every reschedule; a day with nothing to say gets no briefing.
    static func briefings(events: [ScheduleEvent],
                          capped: [String: [PlannedReminder]],
                          preferences: AppPreferences,
                          now: Date,
                          clock: WallClock) -> [PlannedBriefing] {
        let calendar = clock.calendar
        let today = calendar.startOfDay(for: now)
        var result: [PlannedBriefing] = []
        for offset in 0..<briefingDays {
            guard let deliveryDay = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for kind in [PlannedBriefing.Kind.morning, .evening] {
                let time = kind == .morning ? preferences.morningBriefing : preferences.eveningPreview
                guard time.isEnabled,
                      let fire = clock.combine(day: deliveryDay, time: (hour: time.minuteOfDay / 60, minute: time.minuteOfDay % 60)),
                      fire > now else { continue }
                let described = kind == .morning ? deliveryDay : calendar.date(byAdding: .day, value: 1, to: deliveryDay)
                guard let described else { continue }
                // Only the morning briefing of the day the reminders were held back on lists them.
                let held = kind == .morning ? capped[clock.dateString(deliveryDay)] ?? [] : []
                var seen: Set<String> = []
                let heldTitles = held.map(\.event.title).filter { seen.insert($0).inserted }
                guard let content = BriefingBuilder.build(kind: kind, day: described, events: events,
                                                          cappedTitles: heldTitles, clock: clock) else { continue }
                result.append(PlannedBriefing(
                    kind: kind,
                    deliveryDay: deliveryDay,
                    describedDay: clock.dateString(described),
                    fire: fire,
                    content: content,
                    isQuiet: preferences.quietHours.contains(minuteOfDay: time.minuteOfDay),
                    identifier: NotificationIDs.briefingPrefix + "\(kind.rawValue).\(clock.dateString(deliveryDay))"
                ))
            }
        }
        return result.sorted { $0.fire < $1.fire }
    }
}
