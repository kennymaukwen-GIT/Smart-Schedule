import Foundation

/// Which occurrences of a repeating event an edit or a delete applies to. For a one-off event both mean the event.
enum EditScope: String, CaseIterable, Sendable {
    /// This occurrence only («只改這次»): Google keeps it as an exception of the series.
    case thisEvent
    /// Every occurrence («全部»): the series master in Google.
    case allEvents
}

/// What the event page changed; nil = left as it was.
///
/// The double optionals can also clear a value: `location: .some(nil)` (or "") removes the place,
/// `notes: .some(nil)` (or "") clears the notes, `reminderMinutes: .some(nil)` goes back to the defaults for the
/// event's kind and `.some([])` turns its reminders off. A plain `nil` argument means "unchanged", so pass the
/// edited text itself (`notes: text`) rather than nil to clear it.
///
/// Times follow `ScheduleEvent`: an all-day event's `end` is 00:00 of the day after its last day
/// (`allDayEnd(lastDay:calendar:)` and `lastDay(ofAllDayEnd:start:calendar:)` convert for a date-only picker).
/// The easiest way to build one is `EventEdit.changes(from:to:)` with an edited copy of the event.
struct EventEdit: Equatable, Sendable {
    var title: String?
    var start: Date?
    var end: Date?
    var isAllDay: Bool?
    var location: String??
    var notes: String??
    var reminderMinutes: [Int]??

    init(title: String? = nil, start: Date? = nil, end: Date? = nil, isAllDay: Bool? = nil,
         location: String?? = nil, notes: String?? = nil, reminderMinutes: [Int]?? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.reminderMinutes = reminderMinutes
    }

    var isEmpty: Bool { self == EventEdit() }

    /// The edit that turns `original` into `edited` (the page edits a copy): only what differs, compared the way
    /// it is saved (a blank title is ignored, places and notes trimmed, empty means none). "Discard changes?" is
    /// asked when this is not empty.
    static func changes(from original: ScheduleEvent, to edited: ScheduleEvent) -> EventEdit {
        var edit = EventEdit()
        let title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != original.title { edit.title = title }
        let switchesForm = edited.isAllDay != original.isAllDay
        if switchesForm { edit.isAllDay = edited.isAllDay }
        if switchesForm || edited.start != original.start { edit.start = edited.start }
        if switchesForm || edited.end != original.end { edit.end = edited.end }
        let place = edited.location.nonBlank
        if place != original.location.nonBlank { edit.location = .some(place) }
        let notes = EventNotes.normalized(edited.notes)
        if notes != EventNotes.normalized(original.notes) { edit.notes = .some(notes) }
        if edited.reminderMinutes != original.reminderMinutes { edit.reminderMinutes = .some(edited.reminderMinutes) }
        return edit
    }

    /// 00:00 after `lastDay`: the `end` of an all-day event whose last day a date picker shows as `lastDay`.
    static func allDayEnd(lastDay: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: lastDay)
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }

    /// The last day an all-day event covers (what a date picker shows), from its exclusive `end`; never before the
    /// day it starts.
    static func lastDay(ofAllDayEnd end: Date, start: Date, calendar: Calendar) -> Date {
        let first = calendar.startOfDay(for: start)
        let previous = calendar.date(byAdding: .day, value: -1, to: end) ?? end.addingTimeInterval(-86_400)
        return max(first, calendar.startOfDay(for: previous))
    }
}

enum EventEditError: LocalizedError, Equatable {
    /// The end is not after the start.
    case endBeforeStart
    /// "All events" can move every occurrence to another time of day, not to another day.
    case seriesDayChange
    /// "All events" cannot switch every occurrence between all-day and timed.
    case seriesAllDayChange
    /// A preview (draft plan, "Ask me first") is not in a calendar yet.
    case notEditable

    var errorDescription: String? {
        switch self {
        case .endBeforeStart: String(localized: "The end must be after the start.")
        case .seriesDayChange: String(localized: "To move every event to another day, change it in Google Calendar.")
        case .seriesAllDayChange: String(localized: "To make every event all-day or timed, change it in Google Calendar.")
        case .notEditable: String(localized: "Not in your calendar yet")
        }
    }
}

// MARK: - PATCH bodies

extension CalendarEventMapper {
    /// PATCH body for an edit of one event or one occurrence: only what changes (nil fields are left out). Notes go
    /// to `description` as plain text ("" clears it, like "" clears the place). A move keeps the length unless the
    /// end is edited too; switching between all-day and timed sends the other form as null and, while the event uses
    /// its kind's default reminders, the defaults of the new form. Throws `EventEditError.endBeforeStart`.
    func patch(from edit: EventEdit, existing: ScheduleEvent) throws -> GCalEvent {
        var body = fieldsPatch(from: edit, existing: existing)
        let wantsAllDay = edit.isAllDay ?? existing.isAllDay
        guard edit.start != nil || edit.end != nil || wantsAllDay != existing.isAllDay else { return body }
        let times = try resolvedTimes(edit, existing: existing)
        let switches = times.isAllDay != existing.isAllDay
        guard switches || times.start != existing.start || times.end != existing.end else { return body }
        if times.isAllDay {
            body.start = GCalDateTime(date: clock.dateString(times.start), clearsOtherForm: switches)
            body.end = GCalDateTime(date: clock.dateString(times.end), clearsOtherForm: switches)
        } else {
            var start = timed(times.start), end = timed(times.end)
            start.clearsOtherForm = switches
            end.clearsOtherForm = switches
            body.start = start
            body.end = end
        }
        if switches, edit.reminderMinutes == nil, existing.reminderMinutes == nil {
            setReminders(nil, isAllDay: times.isAllDay, kind: existing.kind, in: &body)
        }
        return body
    }

    /// An "All events" edit of a series: the fields go to the series master; a new time of day or length moves every
    /// occurrence (`newStart` and `duration` for `CalendarRouter.patchSeries`, applied to the master's own date).
    /// Throws when the edit moves the occurrence to another day or switches it between all-day and timed: that
    /// changes the recurrence itself, which Google Calendar does better.
    func seriesPatch(from edit: EventEdit,
                     existing: ScheduleEvent) throws -> (body: GCalEvent, newStart: Date?, duration: TimeInterval?) {
        let body = fieldsPatch(from: edit, existing: existing)
        if let isAllDay = edit.isAllDay, isAllDay != existing.isAllDay { throw EventEditError.seriesAllDayChange }
        guard edit.start != nil || edit.end != nil else { return (body, nil, nil) }
        let times = try resolvedTimes(edit, existing: existing)
        guard clock.calendar.isDate(times.start, inSameDayAs: existing.start) else { throw EventEditError.seriesDayChange }
        if existing.isAllDay {
            guard times.end == existing.end else { throw EventEditError.seriesDayChange }
            return (body, nil, nil)
        }
        guard times.start != existing.start || times.end != existing.end else { return (body, nil, nil) }
        return (body, times.start, times.end.timeIntervalSince(times.start))
    }

    /// Title, place, notes and reminders: what an edit changes besides the time.
    func fieldsPatch(from edit: EventEdit, existing: ScheduleEvent) -> GCalEvent {
        var body = GCalEvent()
        if let title = edit.title.nonBlank, title != existing.title { body.summary = title }
        if let location = edit.location {
            let place = location.nonBlank
            if place != existing.location.nonBlank { body.location = place ?? "" }
        }
        if let notes = edit.notes {
            let text = EventNotes.normalized(notes)
            if text != EventNotes.normalized(existing.notes) { body.description = text ?? "" }
        }
        if let reminders = edit.reminderMinutes, reminders != existing.reminderMinutes {
            setReminders(reminders, isAllDay: edit.isAllDay ?? existing.isAllDay, kind: existing.kind, in: &body)
        }
        return body
    }

    /// Where the event will be: an end left alone keeps the length (a new start moves it along); all-day events run
    /// from 00:00 of their first day to 00:00 after their last; an event made timed without a new end lasts the
    /// default length.
    func resolvedTimes(_ edit: EventEdit, existing: ScheduleEvent) throws -> (start: Date, end: Date, isAllDay: Bool) {
        let calendar = clock.calendar
        let isAllDay = edit.isAllDay ?? existing.isAllDay
        let start = edit.start ?? existing.start
        func nextMidnight(_ date: Date) -> Date {
            let day = calendar.startOfDay(for: date)
            return day == date ? day : (calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400))
        }
        func days(_ count: Int, after day: Date) -> Date {
            calendar.date(byAdding: .day, value: count, to: day) ?? day.addingTimeInterval(TimeInterval(count) * 86_400)
        }

        if isAllDay {
            let firstDay = calendar.startOfDay(for: start)
            let endExclusive: Date
            if let end = edit.end {
                endExclusive = nextMidnight(end)
                guard endExclusive > firstDay else { throw EventEditError.endBeforeStart }
            } else if existing.isAllDay {
                // As many days as before (calendar days: a 25-hour DST day is one day).
                let length = calendar.dateComponents([.day], from: calendar.startOfDay(for: existing.start),
                                                     to: calendar.startOfDay(for: existing.end)).day ?? 1
                endExclusive = days(max(1, length), after: firstDay)
            } else {
                // A timed event made all-day covers the days it touched.
                let movedEnd = edit.start == nil ? existing.end : start.addingTimeInterval(existing.duration)
                endExclusive = max(nextMidnight(movedEnd), days(1, after: firstDay))
            }
            return (firstDay, endExclusive, true)
        }

        let end: Date
        if let edited = edit.end {
            end = edited
        } else if existing.isAllDay {
            end = start.addingTimeInterval(TimeInterval(defaultEventMinutes) * 60)
        } else {
            end = edit.start == nil ? existing.end : start.addingTimeInterval(existing.duration)
        }
        guard end > start else { throw EventEditError.endBeforeStart }
        return (start, end, false)
    }

    /// Google's pop-ups and Smart Schedule's own list (`ssReminders`): nil = the kind's defaults, [] = none.
    private func setReminders(_ requested: [Int]?, isAllDay: Bool, kind: ScheduleEvent.Kind, in body: inout GCalEvent) {
        let marker: String
        if let requested, requested.isEmpty {
            body.reminders = ReminderPolicy.noPopups
            marker = Self.noRemindersMarker
        } else if isAllDay {
            body.reminders = policy.googleAllDayReminders(requested: requested)
            marker = localReminders(requested: requested, resolved: policy.allDayMinutes(requested:))
        } else {
            body.reminders = policy.googleReminders(for: kind, requested: requested)
            marker = localReminders(requested: requested) { policy.minutes(for: kind, requested: $0) }
        }
        // Only this key: PATCH merges `private` key by key, so ssKind, ssPlanId and the rest stay.
        body.extendedProperties = GCalExtendedProperties(private: [SSProperty.localReminders: marker])
    }
}

// MARK: - Editor

/// The one place the app changes or deletes an existing event (the event page, the events list's swipe actions).
///
/// Every Google write goes through `CalendarRouter`, like the assistant's: the event's own calendar, If-Match with
/// its cached etag (re-applied once on Google's copy after a 412), the outbox when Google cannot be reached (shown
/// at once, marked waiting to sync, sent by `SyncEngine` later). The cache is updated before this returns, reminders
/// are rescheduled and `SharedChange.syncStatus` is posted, so the calendars, the events list and the other
/// processes read it again. Demo mode edits the cached sample events only and never touches the network.
///
/// Read-only calendars (reader, freeBusyReader): `canEdit` is false and a write throws `RouterError.readOnly`.
actor EventEditor {
    static let shared = EventEditor()

    private let store: SharedStore
    private let accounts: AccountStore
    private let outbox: SyncOutbox
    private let tokens: GoogleTokenProvider
    private let transport: (any CalendarTransport)?
    private let preferences: PreferencesStore
    private let statusDefaults: UserDefaults?
    private let fixedClock: WallClock?
    private let fixedPolicy: ReminderPolicy?
    private let isDemoMode: @Sendable () -> Bool
    private let rescheduleReminders: @Sendable (SharedStore) async -> Void

    /// - Parameters:
    ///   - transport: nil = the network with `tokens`; unit tests pass a stand-in.
    ///   - statusDefaults: where `SyncStatusStore` lives (the App Group); unit tests pass their own suite.
    ///   - clock, policy: nil = Settings (time zone, week start, default reminders), read per call.
    ///   - rescheduleReminders: runs after every change. Unit tests pass a no-op (a hostless test bundle has no
    ///     notification center).
    init(store: SharedStore = .shared,
         accounts: AccountStore = .shared,
         outbox: SyncOutbox = .shared,
         tokens: GoogleTokenProvider = .shared,
         transport: (any CalendarTransport)? = nil,
         preferences: PreferencesStore = .shared,
         statusDefaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID),
         clock: WallClock? = nil,
         policy: ReminderPolicy? = nil,
         isDemoMode: @escaping @Sendable () -> Bool = { AppConstants.isDemoMode },
         rescheduleReminders: @escaping @Sendable (SharedStore) async -> Void = { store in
             await ReminderScheduler.shared.reschedule(store: store)
         }) {
        self.store = store
        self.accounts = accounts
        self.outbox = outbox
        self.tokens = tokens
        self.transport = transport
        self.preferences = preferences
        self.statusDefaults = statusDefaults
        self.fixedClock = clock
        self.fixedPolicy = policy
        self.isDemoMode = isDemoMode
        self.rescheduleReminders = rescheduleReminders
    }

    // MARK: Read-only

    /// False for a preview that is not in a calendar yet and for a calendar the account can only read (the page is
    /// then read-only: "You can't change events in this calendar."). A calendar the account store does not know is
    /// left to Google.
    func canEdit(_ event: ScheduleEvent) async -> Bool {
        let calendars = await accounts.calendars()
        return Self.canEdit(event, in: calendars)
    }

    /// Same, synchronously, against calendars the caller already has (`ScheduleViewModel.accounts`).
    static func canEdit(_ event: ScheduleEvent, in calendars: [CalendarInfo]) -> Bool {
        guard !event.isDraft else { return false }
        guard let ref = event.calendarRef else { return true }
        return calendars.first(where: { $0.id == ref })?.isWritable ?? true
    }

    // MARK: Writes

    /// Saves `edit` and returns the event as it now is (for "All events", the occurrence that was open). Offline,
    /// the change waits in the outbox and the result is marked `isWaitingToSync`. An empty edit changes nothing.
    @discardableResult
    func update(_ event: ScheduleEvent, with edit: EventEdit, scope: EditScope,
                now: Date = Date()) async throws -> ScheduleEvent {
        let current = await cachedCopy(of: event)
        guard !current.isDraft else { throw EventEditError.notEditable }
        guard !edit.isEmpty else { return current }
        let mapper = makeMapper()
        let wholeSeries = scope == .allEvents && current.seriesID != nil

        if isDemoMode() {
            let updated = try await updateLocally(current, with: edit, wholeSeries: wholeSeries, mapper: mapper)
            await finish(queued: false)
            return updated
        }

        let router = makeRouter(clock: mapper.clock)
        if wholeSeries {
            let plan = try mapper.seriesPatch(from: edit, existing: current)
            guard plan.body != GCalEvent() || plan.newStart != nil else { return current }
            let queued = try await router.patchSeries(of: current, body: plan.body, newStart: plan.newStart,
                                                      duration: plan.duration, mapper: mapper, now: now)
            await finish(queued: queued)
            let fallback = Self.occurrence(current, applying: plan.body, newStart: plan.newStart,
                                           duration: plan.duration, clock: mapper.clock)
            return await occurrence(after: current, expected: fallback, clock: mapper.clock) ?? fallback
        }

        let body = try mapper.patch(from: edit, existing: current)
        guard body != GCalEvent() else { return current }
        let saved = try await router.patch(current, body: body, mapper: mapper, now: now)
        let updated = saved ?? OutboxOverlay.applying(body, to: current, clock: mapper.clock)
        await finish(queued: updated.isWaitingToSync)
        return updated
    }

    /// Deletes the event, or with `.allEvents` its whole series, from its calendar (Google keeps it in its Trash).
    /// Offline, the delete waits in the outbox and the event leaves the cache at once.
    func delete(_ event: ScheduleEvent, scope: EditScope, now: Date = Date()) async throws {
        let current = await cachedCopy(of: event)
        guard !current.isDraft else { throw EventEditError.notEditable }
        let target = scope == .allEvents ? (current.seriesID ?? current.id) : current.id
        let ref = EventRef(accountID: current.accountID, calendarID: current.calendarID, eventID: target)

        if isDemoMode() {
            await store.remove([ref], includingSeries: true)
            await finish(queued: false)
            return
        }
        let queued = try await makeRouter(clock: makeMapper().clock).delete([ref], now: now)
        await finish(queued: queued)
    }

    // MARK: Demo

    /// The same changes applied to the cached sample events (every cached occurrence for "All events").
    private func updateLocally(_ event: ScheduleEvent, with edit: EventEdit, wholeSeries: Bool,
                               mapper: CalendarEventMapper) async throws -> ScheduleEvent {
        let clock = mapper.clock
        if wholeSeries, let seriesID = event.seriesID {
            let plan = try mapper.seriesPatch(from: edit, existing: event)
            let occurrences = await store.snapshot().events.filter {
                $0.seriesID == seriesID && $0.calendarRef == event.calendarRef
            }
            let updated = occurrences.map {
                Self.occurrence($0, applying: plan.body, newStart: plan.newStart, duration: plan.duration, clock: clock)
            }
            await store.upsert(updated)
            return updated.first(where: { $0.ref == event.ref })
                ?? Self.occurrence(event, applying: plan.body, newStart: plan.newStart, duration: plan.duration, clock: clock)
        }
        let body = try mapper.patch(from: edit, existing: event)
        let updated = OutboxOverlay.applying(body, to: event, clock: clock)
        await store.upsert([updated])
        return updated
    }

    // MARK: Helpers

    /// One occurrence with a series edit applied: the fields, then the new time of day and length on its own date.
    private static func occurrence(_ event: ScheduleEvent, applying body: GCalEvent, newStart: Date?,
                                   duration: TimeInterval?, clock: WallClock) -> ScheduleEvent {
        var fields = body
        fields.start = nil
        fields.end = nil
        var updated = OutboxOverlay.applying(fields, to: event, clock: clock)
        if let newStart {
            OutboxOverlay.move(&updated, to: OutboxItem.SeriesTime(newStart: newStart, duration: duration ?? event.duration),
                               clock: clock)
        }
        return updated
    }

    /// The open occurrence after a series edit, as the cache now has it. A new time gives Google's instances new
    /// ids (they carry their original start), so it is looked up by series and day when its id is gone.
    private func occurrence(after original: ScheduleEvent, expected: ScheduleEvent, clock: WallClock) async -> ScheduleEvent? {
        let cached = await store.snapshot().events
        if let same = cached.first(where: { $0.ref == original.ref }), same.start == expected.start { return same }
        guard let seriesID = original.seriesID else { return nil }
        return cached.first { candidate in
            candidate.seriesID == seriesID && candidate.calendarRef == original.calendarRef
                && clock.calendar.isDate(candidate.start, inSameDayAs: expected.start)
        }
    }

    /// The cached copy (latest etag, waiting flag, changes made meanwhile); the given one when it is not cached.
    private func cachedCopy(of event: ScheduleEvent) async -> ScheduleEvent {
        await store.snapshot().events.first { $0.ref == event.ref } ?? event
    }

    /// Reminders follow the change; the outbox count is current at once when the change waits; every surface and
    /// process reads the cache again.
    private func finish(queued: Bool) async {
        if queued {
            let waiting = await outbox.pending().count
            SyncStatusStore.update(in: statusDefaults) { $0.pendingCount = waiting }
        }
        await rescheduleReminders(store)
        SharedChangeNotifier.post(.syncStatus)
    }

    private func makeMapper() -> CalendarEventMapper {
        let settings = preferences.current()
        let clock = fixedClock ?? WallClock(timeZone: settings.timeZone, firstWeekday: settings.firstWeekday)
        return CalendarEventMapper(clock: clock, policy: fixedPolicy ?? ReminderPolicy(preferences: settings),
                                   defaultEventMinutes: settings.defaultEventMinutes)
    }

    private func makeRouter(clock: WallClock) -> CalendarRouter {
        CalendarRouter(accounts: accounts, tokens: tokens, store: store, clock: clock, transport: transport, outbox: outbox)
    }
}
