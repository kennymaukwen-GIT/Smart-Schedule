import Foundation

struct MappedEvent: Sendable {
    var body: GCalEvent
    var wantsConference: Bool
}

enum MappingError: LocalizedError {
    case invalidDate(String)
    case emptyPlan

    var errorDescription: String? {
        switch self {
        case let .invalidDate(value): String(localized: "Could not understand the date “\(value)”.")
        case .emptyPlan: String(localized: "The generated plan had no schedulable sessions.")
        }
    }
}

/// Gemini drafts ⇄ Google Calendar Event resources ⇄ ScheduleEvent.
/// Pure value logic (no I/O) so it is unit-testable and shared by app + notification extension.
struct CalendarEventMapper: Sendable {
    let clock: WallClock
    let policy: ReminderPolicy
    /// Length of timed `event` and `routine` items given no end or duration; tasks and deadlines keep 30 min.
    let defaultEventMinutes: Int

    /// Matches the provenance line in Artboard 5's Google Calendar detail view. New events get this one.
    static let provenancePrefix = "由 Smart Schedules 智慧助理自動排程："
    /// What builds before the rename to "Smart Schedules" wrote. Still recognised, so their events keep counting.
    static let legacyProvenancePrefix = "由 Smart Schedule 智慧助理自動排程："
    /// Every provenance prefix the app has written, the current one first.
    static let provenancePrefixes = [provenancePrefix, legacyProvenancePrefix]

    /// Whether `text` starts with a provenance prefix, the current or the legacy one.
    static func startsWithProvenance(_ text: String) -> Bool {
        provenancePrefixes.contains { text.hasPrefix($0) }
    }

    static let schemaVersion = "1"
    /// `ReminderPolicy()`'s all-day default: relative to 00:00 of the event day, 900 = the day before at 09:00.
    static let allDayReminder = [900]
    /// `SSProperty.localReminders` value for "the kind's defaults".
    static let defaultRemindersMarker = "default"
    /// `SSProperty.localReminders` value for "no reminders" (set on the event page).
    static let noRemindersMarker = "none"

    init(clock: WallClock = WallClock(), policy: ReminderPolicy = ReminderPolicy(), defaultEventMinutes: Int = 60) {
        self.clock = clock
        self.policy = policy
        self.defaultEventMinutes = defaultEventMinutes
    }

    /// The mapper for one request, from the current preferences (reminders, source mode, default length). Build it
    /// per request: never keep one in a long-lived object, or a change in Settings would not reach it.
    static func current(clock: WallClock = WallClock()) -> CalendarEventMapper {
        let preferences = PreferencesStore.shared.current()
        return CalendarEventMapper(clock: clock,
                                   policy: ReminderPolicy(preferences: preferences),
                                   defaultEventMinutes: preferences.defaultEventMinutes)
    }

    // MARK: - create_events

    /// The Google body of `draft`, its reminders as asked or else the kind's defaults (no same-day rule).
    func event(from draft: EventDraft, seed: String, utterance: String) throws -> MappedEvent {
        try event(from: draft, seed: seed, utterance: utterance, sameDayFrom: nil)
    }

    /// Same, for an item created at `now`: a timed one-off event, deadline or task without reminders of its own that
    /// starts later that day gets `ReminderPolicy.sameDayMinutes` (10 minutes before and at the start). They are
    /// written as an explicit list, to Google's pop-ups and to `ssReminders` ("10,0"), so this iPhone and Google
    /// agree. Items on later days, all-day and repeating ones, and routines keep the kind's defaults.
    func event(from draft: EventDraft, seed: String, utterance: String, createdAt now: Date) throws -> MappedEvent {
        try event(from: draft, seed: seed, utterance: utterance, sameDayFrom: now)
    }

    /// `sameDayFrom`: when the item is created, for the same-day rule; nil = no same-day rule.
    private func event(from draft: EventDraft, seed: String, utterance: String, sameDayFrom now: Date?) throws -> MappedEvent {
        let kind = ScheduleEvent.Kind(rawValue: draft.kind ?? "") ?? .event
        var body = GCalEvent()
        body.id = GoogleEventID.make(seed: seed)
        body.summary = String(draft.title.prefix(120))
        body.description = description(utterance: utterance, extra: [draft.notes])
        body.location = draft.location.nonBlank
        body.colorId = GoogleColor.colorID(for: kind)

        let isAllDay = draft.allDay == true || !draft.start.contains("T")
        if isAllDay {
            guard let firstDay = clock.date(draft.start) else { throw MappingError.invalidDate(draft.start) }
            let lastDay = max(draft.end.flatMap(clock.date) ?? firstDay, firstDay)
            let endExclusive = clock.calendar.date(byAdding: .day, value: 1, to: lastDay)!
            body.start = GCalDateTime(date: clock.dateString(firstDay))
            body.end = GCalDateTime(date: clock.dateString(endExclusive))
            body.reminders = policy.googleAllDayReminders(requested: draft.reminderMinutes)
            body.extendedProperties = properties(kind: kind, planID: nil,
                                                 reminders: localReminders(requested: draft.reminderMinutes,
                                                                           resolved: policy.allDayMinutes(requested:)))
        } else {
            guard var start = clock.dateTime(draft.start) else { throw MappingError.invalidDate(draft.start) }
            let fallback = TimeInterval(draft.durationMinutes ?? defaultDuration(kind)) * 60
            var end = draft.end.flatMap(clock.dateTime) ?? start.addingTimeInterval(fallback)
            if end <= start {
                // "22:00–01:00" arrives as same-date strings; roll the end into the next day.
                end = end.addingTimeInterval(86_400) > start ? end.addingTimeInterval(86_400) : start.addingTimeInterval(fallback)
            }
            // RFC 5545: DTSTART is always an instance, so align weekly rules to their first BYDAY.
            if let rule = draft.recurrence, rule.frequency.uppercased() == "WEEKLY",
               let aligned = RecurrenceRule.firstMatchingDay(onOrAfter: start, weekdays: rule.byWeekday ?? [], clock: clock),
               aligned != start {
                let length = end.timeIntervalSince(start)
                start = aligned // same wall-clock time, first matching weekday
                end = aligned.addingTimeInterval(length)
            }
            body.start = timed(start)
            body.end = timed(end)
            // Asked-for reminders win; nil and [] both mean "the defaults", as in `ReminderPolicy.minutes`.
            var requested = draft.reminderMinutes
            if requested?.isEmpty != false, draft.recurrence == nil, let now,
               let sameDay = policy.sameDayMinutes(for: kind, start: start, createdAt: now, calendar: clock.calendar) {
                requested = sameDay
            }
            body.reminders = policy.googleReminders(for: kind, requested: requested)
            body.extendedProperties = properties(kind: kind, planID: nil,
                                                 reminders: localReminders(requested: requested) {
                                                     policy.minutes(for: kind, requested: $0)
                                                 })
        }

        if let recurrence = draft.recurrence, let rule = RecurrenceRule.make(from: recurrence, clock: clock) {
            body.recurrence = [rule]
            if body.start?.date != nil { // all-day recurring events still need a zone for UNTIL math
                body.start?.timeZone = clock.timeZone.identifier
                body.end?.timeZone = clock.timeZone.identifier
            }
        }
        let emails = (draft.attendees ?? []).filter { $0.contains("@") && !$0.contains(" ") }
        if !emails.isEmpty { body.attendees = emails.map { GCalAttendee(email: $0) } }

        let wantsMeet = draft.addVideoConference == true
        if wantsMeet { body.conferenceData = .meet(requestID: body.id!) }
        return MappedEvent(body: body, wantsConference: wantsMeet)
    }

    // MARK: - create_long_term_plan

    /// One recurring series per session template per phase (not one event per day): a 6-month,
    /// 4×/week program is ~4–12 API writes instead of ~100, and "move gym to evenings" is one PATCH per series.
    func events(fromPlan plan: LongTermPlanArgs, planID: String, utterance: String) throws -> [MappedEvent] {
        var output: [MappedEvent] = []
        let goalLine = "🎯 \(plan.goal)"

        for (index, session) in plan.sessions.enumerated() {
            guard plan.phases.indices.contains(session.phaseIndex) else { continue }
            let phase = plan.phases[session.phaseIndex]
            guard let phaseStart = clock.date(phase.startDate),
                  let phaseEnd = clock.date(phase.endDate), phaseEnd >= phaseStart,
                  let time = clock.timeOfDay(session.startTime),
                  let firstDay = RecurrenceRule.firstMatchingDay(onOrAfter: phaseStart, weekdays: session.weekdays, clock: clock),
                  firstDay <= phaseEnd,
                  let start = clock.combine(day: firstDay, time: time),
                  let rule = RecurrenceRule.make(frequency: "WEEKLY", byWeekday: session.weekdays, untilDay: phaseEnd, clock: clock)
            else { continue }

            let minutes = min(max(session.durationMinutes, 10), 240)
            var body = GCalEvent()
            body.id = GoogleEventID.make(seed: "\(planID)|session|\(index)")
            body.summary = String("\(plan.planTitle) · \(session.title)".prefix(120))
            body.description = description(utterance: utterance, extra: [
                goalLine,
                "Phase \(session.phaseIndex + 1): \(phase.name)" + (phase.focus.map { " — \($0)" } ?? ""),
                session.notes
            ])
            body.start = timed(start)
            body.end = timed(start.addingTimeInterval(TimeInterval(minutes) * 60))
            body.recurrence = [rule]
            body.colorId = GoogleColor.colorID(for: .routine)
            body.reminders = policy.googleReminders(for: .routine, requested: nil)
            body.extendedProperties = properties(kind: .routine, planID: planID, reminders: Self.defaultRemindersMarker)
            output.append(MappedEvent(body: body, wantsConference: false))
        }

        for (index, milestone) in (plan.milestones ?? []).enumerated() {
            guard let day = clock.date(milestone.date),
                  let next = clock.calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            var body = GCalEvent()
            body.id = GoogleEventID.make(seed: "\(planID)|milestone|\(index)")
            body.summary = String("\(plan.planTitle) · \(milestone.title)".prefix(120))
            body.description = description(utterance: utterance, extra: [goalLine])
            body.start = GCalDateTime(date: clock.dateString(day))
            body.end = GCalDateTime(date: clock.dateString(next))
            body.colorId = GoogleColor.colorID(for: .deadline)
            body.reminders = policy.googleAllDayReminders(requested: nil)
            body.extendedProperties = properties(kind: .deadline, planID: planID, reminders: Self.defaultRemindersMarker)
            output.append(MappedEvent(body: body, wantsConference: false))
        }

        guard output.contains(where: { $0.body.recurrence != nil }) else { throw MappingError.emptyPlan }
        return output
    }

    func nudge(from plan: LongTermPlanArgs, planID: String) -> PlanNudge? {
        guard let draft = plan.dailyNudge,
              let time = clock.timeOfDay(draft.time),
              let endDay = clock.date(plan.endDate),
              let endsOn = clock.calendar.date(byAdding: .day, value: 1, to: endDay) else { return nil }
        return PlanNudge(planID: planID, hour: time.hour, minute: time.minute,
                         message: String(draft.message.prefix(120)), endsOn: endsOn)
    }

    // MARK: - modify_event

    /// PATCH body with only the changed fields (nil fields are omitted by Codable).
    func patch(from changes: EventChangesDraft, existing: ScheduleEvent?) -> GCalEvent {
        var body = GCalEvent()
        body.summary = changes.title.nonBlank
        body.location = changes.location
        // "Add a note": the new text goes on a line of its own below the notes the event has (the assistant only
        // sees them shortened, so it never rewrites them). Plain text, like the event page saves.
        if let note = changes.notes.nonBlank { body.description = EventNotes.appending(note, to: existing?.notes) }

        let duration = changes.durationMinutes.map { TimeInterval($0) * 60 } ?? existing?.duration ?? 3600
        if let newStart = changes.start.flatMap(clock.dateTime) {
            let newEnd = changes.end.flatMap(clock.dateTime) ?? newStart.addingTimeInterval(duration)
            body.start = timed(newStart)
            body.end = timed(max(newEnd, newStart.addingTimeInterval(300)))
        } else if let newEnd = changes.end.flatMap(clock.dateTime) {
            body.end = timed(newEnd)
        } else if changes.durationMinutes != nil, let existing, !existing.isAllDay {
            body.end = timed(existing.start.addingTimeInterval(duration))
        }
        if let requested = changes.reminderMinutes {
            let kind = existing?.kind ?? .event
            if existing?.isAllDay == true {
                body.reminders = policy.googleAllDayReminders(requested: requested)
                body.extendedProperties = GCalExtendedProperties(private: [
                    SSProperty.localReminders: localReminders(requested: requested, resolved: policy.allDayMinutes(requested:))
                ])
            } else {
                body.reminders = policy.googleReminders(for: kind, requested: requested)
                body.extendedProperties = GCalExtendedProperties(private: [
                    SSProperty.localReminders: localReminders(requested: requested) { policy.minutes(for: kind, requested: $0) }
                ])
            }
        }
        return body
    }

    /// Moving a whole series: keep the master's first date, apply the new time of day.
    func seriesTimePatch(master: GCalEvent, newStart: Date, duration: TimeInterval) -> GCalEvent? {
        guard let raw = master.start?.dateTime,
              let masterStart = WallClock.parseRFC3339(raw) ?? clock.dateTime(raw) else { return nil }
        let time = clock.calendar.dateComponents([.hour, .minute], from: newStart)
        guard let start = clock.calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: masterStart)
        else { return nil }
        var body = GCalEvent()
        body.start = timed(start)
        body.end = timed(start.addingTimeInterval(duration))
        return body
    }

    // MARK: - Google → ScheduleEvent

    func scheduleEvent(from event: GCalEvent) -> ScheduleEvent? {
        scheduleEvent(from: event, fallbackColorHex: GoogleColor.calendarDefault)
    }

    /// A listing of one connected calendar: stamped with the account and calendar, the meeting's iCalUID and
    /// organizer flag, and drawn in the calendar's colour unless the event has a colour of its own.
    func scheduleEvent(from event: GCalEvent, in calendar: CalendarInfo) -> ScheduleEvent? {
        guard var mapped = scheduleEvent(from: event, fallbackColorHex: calendar.googleColorHex) else { return nil }
        mapped.accountID = calendar.accountID
        mapped.calendarID = calendar.calendarID
        mapped.iCalUID = event.iCalUID
        mapped.isOrganizer = event.organizer.map { $0.isSelf == true }
        mapped.usesCalendarColor = event.colorId == nil
        return mapped
    }

    private func scheduleEvent(from event: GCalEvent, fallbackColorHex: String) -> ScheduleEvent? {
        guard let id = event.id, event.status != "cancelled",
              let startField = event.start, let endField = event.end else { return nil }
        let props = event.extendedProperties?.private ?? [:]
        let kind = props[SSProperty.kind].flatMap(ScheduleEvent.Kind.init(rawValue:)) ?? Self.inferKind(event.summary)

        let start: Date, end: Date, isAllDay: Bool
        if let day = startField.date, let first = clock.date(day) {
            isAllDay = true
            start = first
            end = endField.date.flatMap(clock.date) ?? first.addingTimeInterval(86_400)
        } else if let raw = startField.dateTime, let parsed = parse(raw) {
            isAllDay = false
            start = parsed
            end = endField.dateTime.flatMap(parse) ?? parsed.addingTimeInterval(3600)
        } else {
            return nil
        }

        let meet = event.hangoutLink
            ?? event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
        return ScheduleEvent(
            id: id,
            seriesID: event.recurringEventId,
            title: event.summary ?? "(No title)",
            start: start,
            end: end,
            isAllDay: isAllDay,
            kind: kind,
            colorHex: event.colorId.flatMap { GoogleColor.palette[$0] } ?? fallbackColorHex,
            location: event.location,
            meetURL: meet.flatMap(URL.init(string:)),
            notes: EventNotes.plainText(fromDescription: event.description),
            reminderMinutes: Self.reminderMinutes(of: event),
            planID: props[SSProperty.planID],
            htmlLink: event.htmlLink.flatMap(URL.init(string:)),
            etag: event.etag,
            departure: Self.departure(from: props)
        )
    }

    // MARK: - Departure reminders

    /// An event's departure settings from its private properties: both values, each valid, or nil. Events without
    /// them (every event made before departure reminders, or by other apps) read as before.
    static func departure(from properties: [String: String]) -> DepartureSettings? {
        guard let early = properties[SSProperty.arriveEarly].flatMap(Int.init),
              DeparturePlanner.arriveEarlyRange.contains(early),
              let mode = properties[SSProperty.travelMode].flatMap(TravelMode.init(rawValue:))
        else { return nil }
        return DepartureSettings(arriveEarlyMinutes: early, travelMode: mode)
    }

    /// The two private properties for `settings`, as Google Calendar keeps them (strings).
    static func departureProperties(_ settings: DepartureSettings) -> [String: String] {
        [SSProperty.arriveEarly: String(settings.arriveEarlyMinutes),
         SSProperty.travelMode: settings.travelMode.rawValue]
    }

    /// PATCH body that adds or replaces an event's departure settings and nothing else; Google keeps the event's other
    /// private properties (a PATCH merges them, as the reminder patches above rely on).
    func departurePatch(_ settings: DepartureSettings) -> GCalEvent {
        var body = GCalEvent()
        body.extendedProperties = GCalExtendedProperties(private: Self.departureProperties(settings))
        return body
    }

    // MARK: - Helpers

    func timed(_ date: Date) -> GCalDateTime {
        GCalDateTime(dateTime: clock.wallDateTimeString(date), timeZone: clock.timeZone.identifier)
    }

    private func parse(_ raw: String) -> Date? {
        WallClock.parseRFC3339(raw) ?? clock.dateTime(raw)
    }

    private func defaultDuration(_ kind: ScheduleEvent.Kind) -> Int {
        switch kind {
        case .event, .routine: defaultEventMinutes
        case .task, .deadline: 30
        }
    }

    /// What `ScheduleEvent.reminderMinutes` means: nil = the kind's defaults (from preferences when reminding),
    /// [] = none, otherwise these minutes. Smart Schedule's own marker wins over Google's pop-ups, which are empty
    /// in "Smart Schedules only" mode ("none" = no reminders). Without it: Google's defaults → nil; overrides →
    /// their minutes; `useDefault == false` with no overrides → [] (reminders turned off in Google).
    static func reminderMinutes(of event: GCalEvent) -> [Int]? {
        if let marker = event.extendedProperties?.private?[SSProperty.localReminders] {
            if marker == defaultRemindersMarker { return nil }
            if marker == noRemindersMarker { return [] }
            let parts = marker.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let minutes = parts.compactMap(Int.init)
            if minutes.count == parts.count { return minutes }
        }
        guard let reminders = event.reminders, !reminders.useDefault else { return nil }
        return reminders.overrides?.map(\.minutes) ?? []
    }

    /// `SSProperty.localReminders` for a write: the marker when the kind's defaults apply, else the explicit
    /// minutes as `resolved` clamps them ("60,10").
    func localReminders(requested: [Int]?, resolved: ([Int]?) -> [Int]) -> String {
        guard let requested, !requested.isEmpty else { return Self.defaultRemindersMarker }
        return resolved(requested).map(String.init).joined(separator: ",")
    }

    private func description(utterance: String, extra: [String?]) -> String {
        ([Self.provenancePrefix + utterance] + extra.compactMap { $0.nonBlank })
            .joined(separator: "\n\n")
    }

    private func properties(kind: ScheduleEvent.Kind, planID: String?, reminders: String) -> GCalExtendedProperties {
        var values = [SSProperty.source: "smart-schedule", SSProperty.kind: kind.rawValue, SSProperty.schema: Self.schemaVersion,
                      SSProperty.localReminders: reminders]
        if let planID { values[SSProperty.planID] = planID }
        return GCalExtendedProperties(private: values)
    }

    static func inferKind(_ title: String?) -> ScheduleEvent.Kind {
        let lower = (title ?? "").lowercased()
        if lower.contains("deadline") || lower.contains("due") || lower.contains("截止") { return .deadline }
        if lower.hasPrefix("reply") || lower.hasPrefix("pay ") || lower.hasPrefix("todo") { return .task }
        return .event
    }
}

extension Optional where Wrapped == String {
    /// nil for nil, empty or whitespace-only strings.
    var nonBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
