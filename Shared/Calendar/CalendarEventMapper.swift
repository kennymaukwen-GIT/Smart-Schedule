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
        case let .invalidDate(value): "Could not understand the date “\(value)”."
        case .emptyPlan: "The generated plan had no schedulable sessions."
        }
    }
}

/// Gemini drafts ⇄ Google Calendar Event resources ⇄ ScheduleEvent.
/// Pure value logic (no I/O) so it is unit-testable and shared by app + notification extension.
struct CalendarEventMapper: Sendable {
    let clock: WallClock
    let policy: ReminderPolicy

    /// Matches the provenance line in Artboard 5's Google Calendar detail view.
    static let provenancePrefix = "由 Smart Schedule 智慧助理自動排程："
    static let schemaVersion = "1"
    /// All-day reminders are relative to 00:00 of the event day; 900 = the day before at 09:00.
    static let allDayReminder = [900]

    init(clock: WallClock = WallClock(), policy: ReminderPolicy = ReminderPolicy()) {
        self.clock = clock
        self.policy = policy
    }

    // MARK: - create_events

    func event(from draft: EventDraft, seed: String, utterance: String) throws -> MappedEvent {
        let kind = ScheduleEvent.Kind(rawValue: draft.kind ?? "") ?? .event
        var body = GCalEvent()
        body.id = GoogleEventID.make(seed: seed)
        body.summary = String(draft.title.prefix(120))
        body.description = description(utterance: utterance, extra: [draft.notes])
        body.location = draft.location.nonBlank
        body.colorId = GoogleColor.colorID(for: kind)
        body.extendedProperties = properties(kind: kind, planID: nil)

        let isAllDay = draft.allDay == true || !draft.start.contains("T")
        if isAllDay {
            guard let firstDay = clock.date(draft.start) else { throw MappingError.invalidDate(draft.start) }
            let lastDay = max(draft.end.flatMap(clock.date) ?? firstDay, firstDay)
            let endExclusive = clock.calendar.date(byAdding: .day, value: 1, to: lastDay)!
            body.start = GCalDateTime(date: clock.dateString(firstDay))
            body.end = GCalDateTime(date: clock.dateString(endExclusive))
            body.reminders = GCalReminders(
                useDefault: false,
                overrides: policy.minutes(for: kind, requested: draft.reminderMinutes ?? Self.allDayReminder)
                    .map { .init(method: "popup", minutes: $0) }
            )
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
            body.reminders = policy.googleReminders(for: kind, requested: draft.reminderMinutes)
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
            body.extendedProperties = properties(kind: .routine, planID: planID)
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
            body.reminders = GCalReminders(useDefault: false, overrides: Self.allDayReminder.map { .init(method: "popup", minutes: $0) })
            body.extendedProperties = properties(kind: .deadline, planID: planID)
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
        if let notes = changes.notes.nonBlank { body.description = notes }

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
            body.reminders = policy.googleReminders(for: existing?.kind ?? .event, requested: requested)
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
            colorHex: event.colorId.flatMap { GoogleColor.palette[$0] } ?? GoogleColor.calendarDefault,
            location: event.location,
            meetURL: meet.flatMap(URL.init(string:)),
            notes: event.description,
            reminderMinutes: event.reminders?.useDefault == false ? event.reminders?.overrides?.map(\.minutes) : nil,
            planID: props[SSProperty.planID],
            htmlLink: event.htmlLink.flatMap(URL.init(string:))
        )
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
        case .event, .routine: 60
        case .task, .deadline: 30
        }
    }

    private func description(utterance: String, extra: [String?]) -> String {
        ([Self.provenancePrefix + utterance] + extra.compactMap { $0.nonBlank })
            .joined(separator: "\n\n")
    }

    private func properties(kind: ScheduleEvent.Kind, planID: String?) -> GCalExtendedProperties {
        var values = [SSProperty.source: "smart-schedule", SSProperty.kind: kind.rawValue, SSProperty.schema: Self.schemaVersion]
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
