import Foundation

enum DemoCalendarError: LocalizedError {
    /// A write reached a sample calendar after demo mode ended (a request that was still running when the user left
    /// it).
    case demoEnded
    /// A write reached a real calendar while new events go to a sample one (demo mode, and always on demo mode's own
    /// router).
    case sampleCalendarsOnly

    var errorDescription: String? {
        switch self {
        case .demoEnded: String(localized: "Demo mode has ended, so nothing was changed.")
        case .sampleCalendarsOnly: String(localized: "Demo mode changes only the sample calendars, so nothing was changed.")
        }
    }
}

/// The sample calendars (`DemoData.accounts`) live on this iPhone only. A write the router sends to one changes
/// `SharedStore` and nothing else: new events get `demo-` ids (the ids demo mode shows), and no token, outbox item,
/// listing or Google request is made. Every such write first checks that demo mode is still on, as the cache's own
/// account store sees it (the live flag, not the router's accounts, which a demo router pins to the samples), and
/// throws `DemoCalendarError.demoEnded` otherwise.
///
/// Repeats: weekly series, and daily ones without an interval, expand `PlanDraftBuilder.previewWeeks` weeks ahead,
/// as plan previews do; any other repeating event is added once.
extension CalendarRouter {
    /// A calendar of a sample account. Real account ids are OpenID `sub` values, which never start with "demo-".
    static func isSample(_ calendar: CalendarRef) -> Bool {
        DemoData.isDemoID(calendar.accountID)
    }

    /// Throws `DemoCalendarError.sampleCalendarsOnly` while new events go to a sample calendar: in demo mode, and
    /// always on a router pinned to the samples (`AccountStore.sampleCalendarsOnly()`), no real calendar is written,
    /// whatever ref reaches the router (a hidden copy of a real event, an id Gemini made up). Called before any token,
    /// outbox item or Google request for a real calendar.
    func requireRealCalendarWritable() async throws {
        guard let target = try? await defaultTarget(), Self.isSample(target.id) else { return }
        throw DemoCalendarError.sampleCalendarsOnly
    }

    /// Throws `DemoCalendarError.demoEnded` once demo mode is off. A cache without an account store (unit tests)
    /// counts as on.
    func requireDemoActive() async throws {
        let rules = await store.visibilityRules()
        guard rules.isDemoMode || !rules.separatesDemoEvents else { throw DemoCalendarError.demoEnded }
    }

    /// `insert` into a sample calendar: the events, or a series' occurrences, cached with `demo-` ids and stamped with
    /// the calendar, as a Google listing would stamp them.
    func insertSample(_ events: [MappedEvent], into target: CalendarInfo, mapper: CalendarEventMapper,
                      now: Date) async throws -> [ScheduleEvent] {
        try await requireDemoActive()
        let days = 7 * PlanDraftBuilder.previewWeeks
        let horizon = mapper.clock.calendar.date(byAdding: .day, value: days, to: now)
            ?? now.addingTimeInterval(TimeInterval(days) * 86_400)
        var saved: [ScheduleEvent] = []
        for event in events {
            let body = event.body
            var copies = body.recurrence == nil ? [] : RecurrenceExpander.instances(
                of: Self.weeklyEquivalent(body), through: horizon, idPrefix: DemoData.idPrefix, mapper: mapper)
            if copies.isEmpty, var single = mapper.scheduleEvent(from: body) {
                single.id = DemoData.idPrefix + single.id
                single.seriesID = single.seriesID.map { DemoData.idPrefix + $0 }
                copies = [single]
            }
            saved += copies.map { instance in
                var copy = instance
                copy.accountID = target.accountID
                copy.calendarID = target.calendarID
                copy.usesCalendarColor = body.colorId == nil
                if body.colorId == nil { copy.colorHex = target.googleColorHex }
                return copy
            }
        }
        await store.upsert(saved)
        return saved
    }

    /// An every-day `RRULE:FREQ=DAILY` (no INTERVAL above 1) as the weekly rule `RecurrenceExpander` expands:
    /// FREQ=WEEKLY on the same BYDAY days, or on every day of the week; UNTIL and COUNT stay. Any other body is
    /// returned unchanged.
    static func weeklyEquivalent(_ body: GCalEvent) -> GCalEvent {
        guard let rules = body.recurrence,
              let index = rules.firstIndex(where: { $0.hasPrefix("RRULE:") }),
              let rule = RecurrenceExpander.Rule(rules[index]),
              rule.frequency == "DAILY", rule.interval == 1 else { return body }
        let replaced: Set<String> = ["FREQ", "INTERVAL", "BYDAY"]
        let kept = rules[index].dropFirst("RRULE:".count).split(separator: ";").map(String.init).filter { part in
            let name = part.split(separator: "=", maxSplits: 1).first.map { $0.uppercased() } ?? ""
            return !replaced.contains(name)
        }
        let weekdays = rule.weekdays.isEmpty ? ["MO", "TU", "WE", "TH", "FR", "SA", "SU"] : rule.weekdays
        let fields = ["FREQ=WEEKLY", "BYDAY=" + weekdays.joined(separator: ",")] + kept
        var weekly = body
        weekly.recurrence?[index] = "RRULE:" + fields.joined(separator: ";")
        return weekly
    }

    /// `patch` of a sample event: the change applied to its cached copy.
    func patchSample(_ event: ScheduleEvent, body: GCalEvent, mapper: CalendarEventMapper) async throws -> ScheduleEvent? {
        try await requireDemoActive()
        let current = await store.snapshot().events.first { $0.ref == event.ref } ?? event
        let updated = OutboxOverlay.applying(body, to: current, clock: mapper.clock)
        await store.upsert([updated])
        return updated
    }

    /// `patchSeries` of a sample series: every cached occurrence in the event's calendar gets the fields and, with
    /// `newStart`, its time of day for `duration` on the occurrence's own date (as `EventEditor` edits demo events).
    func patchSampleSeries(of event: ScheduleEvent, body: GCalEvent, newStart: Date?, duration: TimeInterval?,
                           mapper: CalendarEventMapper) async throws {
        try await requireDemoActive()
        let series = event.seriesID ?? event.id
        let occurrences = await store.snapshot().events.filter { copy in
            (copy.seriesID == series || copy.id == series) && copy.calendarRef == event.calendarRef
        }
        let updated = occurrences.map { copy in
            EventEditor.occurrence(copy, applying: body, newStart: newStart, duration: duration, clock: mapper.clock)
        }
        await store.upsert(updated)
    }

    /// A plan's sample events as refs (`planEventRefs`): a series once, by its series id; a one-off by its id.
    func samplePlanRefs(planID: String) async -> [EventRef] {
        let cached = await store.snapshot().events
        var seen = Set<EventRef>()
        return cached
            .filter { DemoData.isDemoID($0.id) && $0.planID == planID }
            .map { EventRef(accountID: $0.accountID, calendarID: $0.calendarID, eventID: $0.seriesID ?? $0.id) }
            .filter { seen.insert($0).inserted }
    }
}
