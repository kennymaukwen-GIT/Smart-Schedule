import Foundation

/// The drawer's Events section, the events list and the event page: which events are managed there, and the
/// writes the page makes. Rows come from `events` (the visible calendars) without draft ghosts, so they change with
/// the cache: whatever the assistant, a plan, Siri, the notification extension or a sync adds shows up, and what
/// was deleted leaves. `EventDigest` sorts them into rows and sections; the views ask again every minute, so an
/// event leaves once it has ended.
extension ScheduleViewModel {
    /// How far ahead the events list reaches (its footnote says so).
    static let eventsListMonths = 12

    /// One section of the events list, in display order.
    struct ManagedEventGroup {
        var section: ManagedEventSection
        var rows: [ManagedEventRow]
    }

    /// Events of calendars shown in Smart Schedule that have not ended and start within `eventsListMonths`. A
    /// calendar hidden a moment ago is left out at once, before the cache reloads.
    func managedEvents(now: Date) -> [ScheduleEvent] {
        let hidden = Set(accounts.lazy.flatMap(\.calendars).filter { !$0.isVisible }.map(\.id))
        let horizon = clock.calendar.date(byAdding: .month, value: Self.eventsListMonths, to: now)
            ?? now.addingTimeInterval(365 * 86_400)
        return events.filter { event in
            guard !event.isDraft, event.end > now, event.start < horizon else { return false }
            if let ref = event.calendarRef, hidden.contains(ref) { return false }
            return true
        }
    }

    /// Every row of the events list: one-off events one by one, a repeating series once (its occurrence under way,
    /// else its next one).
    func managedRows(now: Date) -> [ManagedEventRow] {
        EventDigest.rows(from: managedEvents(now: now), now: now, calendar: clock.calendar)
    }

    /// The drawer's "now and next": what is under way, then the soonest.
    func upcomingRows(_ rows: [ManagedEventRow], limit: Int) -> [ManagedEventRow] {
        EventDigest.upcoming(rows, limit: limit)
    }

    /// Now, Today, Tomorrow, This week, Later, Repeating; empty sections left out.
    func managedSections(_ rows: [ManagedEventRow], now: Date) -> [ManagedEventGroup] {
        EventDigest.sections(rows, now: now, calendar: clock.calendar).map { ManagedEventGroup(section: $0.0, rows: $0.1) }
    }

    /// The search field: title, place and notes.
    func rows(_ rows: [ManagedEventRow], matching query: String) -> [ManagedEventRow] {
        rows.filter { EventDigest.matches($0, query: query) }
    }

    /// "Every Sat 09:00" / 「每週六 09:00」 for a repeating series row, read from every cached occurrence.
    func repeatSummary(for row: ManagedEventRow, locale: Locale) -> String? {
        guard row.event.seriesID != nil else { return nil }
        return EventDigest.repeatSummary(for: row.event, occurrences: EventDigest.occurrences(of: row, in: events),
                                         calendar: clock.calendar, locale: locale)
    }

    /// The same for one occurrence (the event page); nil when it does not repeat.
    func repeatSummary(of event: ScheduleEvent, locale: Locale) -> String? {
        guard let seriesID = event.seriesID else { return nil }
        let occurrences = events.filter { $0.seriesID == seriesID && $0.calendarRef == event.calendarRef && !$0.isDraft }
        return EventDigest.repeatSummary(for: event, occurrences: occurrences, calendar: clock.calendar, locale: locale)
    }

    /// The events list opens: the next 12 months are loaded if the cache lacks any of them (`isLoadingRange` shows
    /// meanwhile).
    func loadUpcomingEvents(now: Date = Date()) {
        let calendar = clock.calendar
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .month, value: Self.eventsListMonths, to: start)
            ?? start.addingTimeInterval(365 * 86_400)
        ensureEvents(covering: DateInterval(start: start, end: end))
    }

    // MARK: The event page

    /// The calendar an event lives in (nil for events cached before accounts existed).
    func calendarInfo(of event: ScheduleEvent) -> CalendarInfo? {
        event.calendarRef.flatMap { calendar($0) }
    }

    /// In a calendar the account can only read (or only sees as free/busy): the page shows it without editing.
    func isReadOnly(_ event: ScheduleEvent) -> Bool {
        !EventEditor.canEdit(event, in: accounts.flatMap(\.calendars))
    }

    /// The cached event a chat card's event stands for, so "Manage" opens what the calendars show: the same id,
    /// else (a repeating event the assistant added) the next occurrence of its series. nil when the cache no longer
    /// has it.
    func manageableEvent(for added: ScheduleEvent, now: Date = Date()) -> ScheduleEvent? {
        guard !added.isDraft else { return nil }
        if let cached = event(id: added.id) { return cached }
        let occurrences = events.filter { $0.seriesID == added.id }
        return occurrences.first { $0.end > now } ?? occurrences.last
    }

    /// Save on the event page: through `EventEditor` (Google with If-Match, or the outbox while Google cannot be
    /// reached; it reschedules reminders), then the calendars, the list and the island show the result at once.
    /// A failure is read back too: an event deleted in Google meanwhile has left the cache.
    @discardableResult
    func updateEvent(_ event: ScheduleEvent, with edit: EventEdit, scope: EditScope) async throws -> ScheduleEvent {
        do {
            let saved = try await EventEditor.shared.update(event, with: edit, scope: scope)
            await afterEventWrite()
            return saved
        } catch {
            await afterEventWrite()
            throw error
        }
    }

    /// Delete on the event page or a list row; `.allEvents` deletes the whole series. After a failure too: what
    /// was deleted until then has left the cache.
    func deleteEvent(_ event: ScheduleEvent, scope: EditScope) async throws {
        do {
            try await EventEditor.shared.delete(event, scope: scope)
        } catch {
            await afterEventWrite()
            throw error
        }
        await afterEventWrite()
    }

    private func afterEventWrite() async {
        syncStatus = SyncStatusStore.current
        await reloadFromCache()
        await LiveActivityManager.shared.refreshIfRunning()
    }
}
