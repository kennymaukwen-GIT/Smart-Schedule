import Foundation

enum RouterError: LocalizedError {
    /// A write to a calendar the account can only read.
    case readOnly(String)

    var errorDescription: String? {
        switch self {
        case let .readOnly(name): String(localized: "You can't change events in “\(name)”.")
        }
    }
}

/// Every Google write the assistant makes, sent to the right account and calendar, with the cache kept in step.
///
/// New events go to the default write target (`AccountStore.defaultWriteTarget()`). Existing events carry their
/// account and calendar, so edits and deletes go to the copy's own calendar (after de-duplication, the organizer's
/// or a writable copy). Events without one (pre-migration) go to the default target. Before the single-account
/// sign-in is migrated, everything goes to its primary calendar, as before.
struct CalendarRouter: Sendable {
    var accounts: AccountStore = .shared
    var tokens: GoogleTokenProvider = .shared
    var store: SharedStore = .shared
    var clock = WallClock()

    /// Where a plan's series are searched for, around `now`.
    static let planSearchPast: TimeInterval = 365 * 86_400
    static let planSearchFuture: TimeInterval = 730 * 86_400

    func defaultTarget() async throws -> CalendarInfo {
        if let target = await accounts.defaultWriteTarget() { return target }
        if await accounts.connectedAccounts().isEmpty, tokens.hasLegacyTokens { return Self.legacyTarget }
        throw AuthError.signedOut
    }

    /// The client for a calendar; nil = the default target's.
    func client(for calendar: CalendarRef?) async -> GoogleCalendarClient {
        if let calendar {
            return GoogleCalendarClient(accountID: calendar.accountID, calendarID: calendar.calendarID, tokens: tokens)
        }
        guard let target = try? await defaultTarget() else { return GoogleCalendarClient(tokens: tokens) }
        return makeClient(target)
    }

    /// Inserts (idempotent ids), returns saved events stamped with account/calendar. Upserts them into the cache;
    /// when any is recurring, re-lists that calendar's rolling window instead.
    func insert(_ events: [MappedEvent], into target: CalendarInfo, mapper: CalendarEventMapper, now: Date) async throws -> [ScheduleEvent] {
        guard !events.isEmpty else { return [] }
        try Self.requireWritable(target)
        let saved: [GCalEvent]
        do {
            saved = try await makeClient(target).insertAll(events)
        } catch {
            throw Self.writeError(error, calendar: target)
        }
        let mapped = saved.compactMap { cachedEvent(from: $0, in: target, mapper: mapper) }
        if saved.contains(where: { $0.recurrence != nil }) {
            await refresh(calendar: target.id, now: now)
        } else {
            await store.upsert(mapped)
        }
        return mapped
    }

    /// PATCH one event or instance in its own calendar; upserts the result.
    func patch(_ event: ScheduleEvent, body: GCalEvent, mapper: CalendarEventMapper) async throws -> ScheduleEvent? {
        let calendar = try await owningCalendar(of: event)
        try Self.requireWritable(calendar)
        let saved: GCalEvent
        do {
            saved = try await makeClient(calendar).patch(eventID: event.id, body)
        } catch {
            throw Self.writeError(error, calendar: calendar)
        }
        guard let updated = cachedEvent(from: saved, in: calendar, mapper: mapper) else { return nil }
        await store.upsert([updated])
        return updated
    }

    /// GET the series master of `event` (its `seriesID`; the event itself when it is not an instance) in the event's
    /// calendar.
    func master(of event: ScheduleEvent) async throws -> GCalEvent {
        let calendar = try await owningCalendar(of: event)
        return try await makeClient(calendar).get(eventID: event.seriesID ?? event.id)
    }

    /// PATCH the series master, then re-list that calendar's rolling window.
    func patchSeries(of event: ScheduleEvent, body: GCalEvent, now: Date) async throws {
        let calendar = try await owningCalendar(of: event)
        try Self.requireWritable(calendar)
        do {
            _ = try await makeClient(calendar).patch(eventID: event.seriesID ?? event.id, body)
        } catch {
            throw Self.writeError(error, calendar: calendar)
        }
        await refresh(calendar: calendar.id, now: now)
    }

    /// Deletes each ref in its own calendar (404/410 = done) and removes those copies, and the instances of a ref
    /// that names a series, from the cache. Refs without a calendar go to the default target. Stops at the first
    /// failure; what was deleted until then leaves the cache too.
    func delete(_ refs: [EventRef]) async throws {
        var fallback: CalendarInfo?
        var deleted: [EventRef] = []
        var failure: Error?
        for ref in refs {
            do {
                let calendar: CalendarInfo
                if let accountID = ref.accountID, let calendarID = ref.calendarID {
                    calendar = await calendarInfo(CalendarRef(accountID: accountID, calendarID: calendarID))
                } else if let fallback {
                    calendar = fallback
                } else {
                    calendar = try await defaultTarget()
                    fallback = calendar
                }
                try Self.requireWritable(calendar)
                do {
                    try await makeClient(calendar).delete(eventID: ref.eventID)
                } catch {
                    throw Self.writeError(error, calendar: calendar)
                }
                deleted.append(ref)
                if ref.accountID == nil, !Self.isLegacy(calendar) {
                    // The cached copy may carry the calendar the request did not name.
                    deleted.append(EventRef(accountID: calendar.accountID, calendarID: calendar.calendarID, eventID: ref.eventID))
                }
            } catch {
                failure = error
                break
            }
        }
        if !deleted.isEmpty { await store.remove(deleted, includingSeries: true) }
        if let failure { throw failure }
    }

    /// Series masters of a plan across all writable synced calendars (a plan lives where it was added).
    func planEventRefs(planID: String, now: Date) async throws -> [EventRef] {
        let from = now.addingTimeInterval(-Self.planSearchPast), to = now.addingTimeInterval(Self.planSearchFuture)
        let property = (key: SSProperty.planID, value: planID)
        let writable = await accounts.syncedCalendars().filter(\.isWritable)
        guard !writable.isEmpty else {
            let target = try await defaultTarget()
            let masters = try await makeClient(target).list(from: from, to: to, singleEvents: false, privateProperty: property)
            return masters.compactMap { master in
                master.id.map { EventRef(accountID: Self.accountID(of: target), calendarID: Self.calendarID(of: target), eventID: $0) }
            }
        }
        var refs: [EventRef] = []
        var firstError: Error?
        for calendar in writable {
            do {
                let masters = try await makeClient(calendar).list(from: from, to: to, singleEvents: false, privateProperty: property)
                refs += masters.compactMap { master in
                    master.id.map { EventRef(accountID: calendar.accountID, calendarID: calendar.calendarID, eventID: $0) }
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if refs.isEmpty, let firstError { throw firstError }
        return refs
    }

    /// Re-lists one calendar's rolling window (after writes). Failures keep the cache as it was.
    func refresh(calendar: CalendarRef, now: Date) async {
        try? await CalendarSync(store: store, accounts: accounts, tokens: tokens, clock: clock,
                                calendars: calendar == Self.legacyTarget.id ? nil : [calendar])
            .refreshWindow(now: now)
    }

    // MARK: Helpers

    /// Stand-in for the single-account sign-in before migration: its primary calendar, events cached unscoped.
    private static let legacyTarget = CalendarInfo(accountID: "", accountEmail: "", calendarID: "primary",
                                                   name: "primary", isPrimary: true, accessRole: "owner")

    private static func isLegacy(_ calendar: CalendarInfo) -> Bool { calendar.accountID.isEmpty }
    private static func accountID(of calendar: CalendarInfo) -> String? { isLegacy(calendar) ? nil : calendar.accountID }
    private static func calendarID(of calendar: CalendarInfo) -> String? { isLegacy(calendar) ? nil : calendar.calendarID }

    private func makeClient(_ calendar: CalendarInfo) -> GoogleCalendarClient {
        GoogleCalendarClient(accountID: Self.accountID(of: calendar), calendarID: calendar.calendarID, tokens: tokens)
    }

    private func cachedEvent(from event: GCalEvent, in calendar: CalendarInfo, mapper: CalendarEventMapper) -> ScheduleEvent? {
        Self.isLegacy(calendar) ? mapper.scheduleEvent(from: event) : mapper.scheduleEvent(from: event, in: calendar)
    }

    /// The calendar an existing copy lives in; the default target for copies cached without one.
    private func owningCalendar(of event: ScheduleEvent) async throws -> CalendarInfo {
        guard let ref = event.calendarRef else { return try await defaultTarget() }
        return await calendarInfo(ref)
    }

    /// A calendar the account store no longer lists (removed meanwhile) is still addressed by its ids; Google
    /// decides whether the write is allowed.
    private func calendarInfo(_ ref: CalendarRef) async -> CalendarInfo {
        if let known = await accounts.calendar(ref) { return known }
        let email = await accounts.connectedAccount(id: ref.accountID)?.email ?? ""
        return CalendarInfo(accountID: ref.accountID, accountEmail: email, calendarID: ref.calendarID,
                            name: ref.calendarID, isPrimary: ref.calendarID == email, accessRole: "writer")
    }

    private static func requireWritable(_ calendar: CalendarInfo) throws {
        guard calendar.isWritable else { throw RouterError.readOnly(calendar.displayName) }
    }

    /// Google's "you need writer access" (`requiredAccessLevel`, e.g. access changed since the calendar list was
    /// read) reads as "You can't change events in …". Rate limits were retried by the client already.
    private static func writeError(_ error: Error, calendar: CalendarInfo) -> Error {
        guard case let .http(status, reason, _)? = error as? CalendarAPIError, status == 403,
              reason == "requiredAccessLevel" || !calendar.isWritable else { return error }
        return RouterError.readOnly(calendar.displayName)
    }
}
